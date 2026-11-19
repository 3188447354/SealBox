// SBMachOPatcher.c — Mach-O 补丁器实现：只用公开系统头文件，从零写成。
//
// 流程：整文件读进内存 → thin 包直接处理、fat 包逐个处理 arm64/arm64e 切片 →
// 全部切片通过校验后才一次性写回。加密检测在任何修改前完成，加密包原样不动。

#include "SBMachOPatcher.h"

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libkern/OSByteOrder.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach/machine.h>

// LC_DYLD_CHAINED_FIXUPS 指向的数据结构（只取本文件校验需要的头两个字段）。
struct sb_chained_fixups_header {
    uint32_t fixups_version;
    uint32_t starts_offset;
    uint32_t imports_offset;
    uint32_t symbols_offset;
    uint32_t imports_count;
    uint32_t imports_format;
    uint32_t symbols_format;
};

struct sb_chained_starts_in_image {
    uint32_t seg_count;
    uint32_t seg_info_offset[1];
};

// 本模块注入的两条 LC_RPATH。
static const char *kSBRPathTweaks = "@executable_path/../../Tweaks";
static const char *kSBRPathLoader = "@loader_path";

static uint32_t sb_align_up_u32(uint32_t value, uint32_t alignment) {
    return (uint32_t)((value + alignment - 1) & ~(alignment - 1));
}

// 区间 [offset, offset + length) 是否完整落在 [0, total) 内。
static int sb_range_ok(size_t offset, size_t length, size_t total) {
    return offset <= total && length <= total - offset;
}

static uint8_t *sb_read_file(const char *path, size_t *out_size) {
    FILE *fp = fopen(path, "rb");
    if (fp == NULL) {
        return NULL;
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return NULL;
    }
    long size = ftell(fp);
    if (size <= 0) {
        fclose(fp);
        return NULL;
    }
    if (fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        return NULL;
    }
    uint8_t *buffer = (uint8_t *)malloc((size_t)size);
    if (buffer == NULL) {
        fclose(fp);
        return NULL;
    }
    if (fread(buffer, 1, (size_t)size, fp) != (size_t)size) {
        free(buffer);
        fclose(fp);
        return NULL;
    }
    fclose(fp);
    *out_size = (size_t)size;
    return buffer;
}

static int sb_write_file(const char *path, const uint8_t *buffer, size_t size) {
    FILE *fp = fopen(path, "wb");
    if (fp == NULL) {
        return 0;
    }
    size_t written = fwrite(buffer, 1, size, fp);
    int ok = (written == size);
    if (fclose(fp) != 0) {
        ok = 0;
    }
    return ok;
}

// 在 dst 处写一条 LC_LOAD_DYLIB，名字为 name，cmdsize 由调用方保证足够。
// 名字字符串放在结构体之后（偏移 = sizeof(struct dylib_command)），
// name.offset 字段填的正是这个偏移。
static void sb_write_dylib_command(uint8_t *dst, uint32_t cmdsize, const char *name) {
    memset(dst, 0, cmdsize);
    struct dylib_command *dc = (struct dylib_command *)dst;
    dc->cmd = LC_LOAD_DYLIB;
    dc->cmdsize = cmdsize;
    dc->dylib.name.offset = (uint32_t)sizeof(struct dylib_command);
    dc->dylib.timestamp = 2;
    dc->dylib.current_version = 0;
    dc->dylib.compatibility_version = 0;
    memcpy(dst + sizeof(struct dylib_command), name, strlen(name) + 1);
}

// 在 dst 处写一条 LC_ID_DYLIB，install name 为 name（调用方保证是 basename）。
// 名字字符串放在结构体之后（偏移 = sizeof(struct dylib_command)）。
// current/compat version 取 0x10000，与 LiveContainer 一致。
static void sb_write_id_dylib_command(uint8_t *dst, uint32_t cmdsize, const char *name) {
    memset(dst, 0, cmdsize);
    struct dylib_command *dc = (struct dylib_command *)dst;
    dc->cmd = LC_ID_DYLIB;
    dc->cmdsize = cmdsize;
    dc->dylib.name.offset = (uint32_t)sizeof(struct dylib_command);
    dc->dylib.timestamp = 2;
    dc->dylib.current_version = 0x10000;
    dc->dylib.compatibility_version = 0x10000;
    memcpy(dst + sizeof(struct dylib_command), name, strlen(name) + 1);
}

// 在 dst 处写一条 LC_RPATH，路径为 rpath，cmdsize 由调用方保证足够。
// 路径字符串放在结构体之后（偏移 = sizeof(struct rpath_command)）。
static void sb_write_rpath_command(uint8_t *dst, uint32_t cmdsize, const char *rpath) {
    memset(dst, 0, cmdsize);
    struct rpath_command *rc = (struct rpath_command *)dst;
    rc->cmd = LC_RPATH;
    rc->cmdsize = cmdsize;
    rc->path.offset = (uint32_t)sizeof(struct rpath_command);
    memcpy(dst + sizeof(struct rpath_command), rpath, strlen(rpath) + 1);
}

// 用加载命令区末尾的空闲空间追加一条 LC_RPATH；空间不足返回 NO_SPACE。
static int32_t sb_add_rpath(uint8_t *base, struct mach_header_64 *header,
                            size_t free_end, const char *rpath) {
    uint32_t needed = sb_align_up_u32(
        (uint32_t)sizeof(struct rpath_command) + (uint32_t)strlen(rpath) + 1, 8);
    size_t cmds_end = sizeof(struct mach_header_64) + header->sizeofcmds;
    size_t slack = (free_end > cmds_end) ? (free_end - cmds_end) : 0;
    if (slack < needed) {
        return SB_MACHO_PATCH_ERR_NO_SPACE;
    }
    sb_write_rpath_command(base + cmds_end, needed, rpath);
    header->ncmds += 1;
    header->sizeofcmds += needed;
    return SB_MACHO_PATCH_OK;
}

// 对一个 thin 的 arm64/arm64e 切片打补丁（base 指向切片首字节，size 为切片长度）。
// 只改内存，不写文件；返回 SB_MACHO_PATCH_OK 或错误码。
// id_name 是可执行文件名（basename），用于 LC_ID_DYLIB；为 NULL 或空串时不插。
// seg_mismatch_out 非 NULL 时，链式修正段数不一致只置标记、不报错（0.2.5，见头文件）。
static int32_t sb_patch_thin_slice(uint8_t *base, size_t size, const char *hooks_path,
                                   const char *id_name, int *seg_mismatch_out) {
    if (size < sizeof(struct mach_header_64)) {
        return SB_MACHO_PATCH_ERR_NOT_MACHO;
    }
    struct mach_header_64 *header = (struct mach_header_64 *)base;
    if (header->magic == MH_MAGIC) {
        // 32 位 thin 包。
        return SB_MACHO_PATCH_ERR_UNSUPPORTED_32BIT;
    }
    if (header->magic != MH_MAGIC_64) {
        return SB_MACHO_PATCH_ERR_NOT_MACHO;
    }
    if (header->cputype == CPU_TYPE_ARM) {
        return SB_MACHO_PATCH_ERR_UNSUPPORTED_32BIT;
    }
    if (header->cputype != CPU_TYPE_ARM64) {
        return SB_MACHO_PATCH_ERR_UNSUPPORTED_ARCH;
    }
    if (header->filetype != MH_EXECUTE && header->filetype != MH_DYLIB) {
        return SB_MACHO_PATCH_ERR_NOT_MACHO;
    }
    if (header->ncmds == 0) {
        return SB_MACHO_PATCH_ERR_NOT_MACHO;
    }
    size_t cmds_begin = sizeof(struct mach_header_64);
    size_t cmds_end = cmds_begin + header->sizeofcmds;
    if (cmds_end > size) {
        return SB_MACHO_PATCH_ERR_NOT_MACHO;
    }

    // ---- 第一遍扫描：只收集信息，不改任何字节。加密在此发现，直接返回。----
    uint32_t seg_count = 0;
    struct segment_command_64 *pagezero_cmd = NULL;
    struct linkedit_data_command *fixups_cmd = NULL;
    size_t dylinker_off = 0;
    uint32_t dylinker_size = 0;
    int has_dylinker = 0;
    int has_hooks_dylib = 0;
    int has_id_dylib = 0;
    int has_rpath_tweaks = 0;
    int has_rpath_loader = 0;
    // 0.2.16：LC_MAIN 的位置与大小（第二遍去掉它；只记第一条，多条是
    // 损坏文件，打完校验会拦）。lc_main_size == 0 表示没有 LC_MAIN。
    size_t lc_main_off = 0;
    uint32_t lc_main_size = 0;
    // 加载命令区末尾到第一份文件内容之间的空闲空间上界：
    // 取所有 section offset 与文件内容起点（fileoff >= 加载命令区末尾）的最小值。
    size_t free_end = size;

    size_t p = cmds_begin;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (!sb_range_ok(p, sizeof(struct load_command), cmds_end)) {
            return SB_MACHO_PATCH_ERR_NOT_MACHO;
        }
        struct load_command *lc = (struct load_command *)(base + p);
        if (lc->cmdsize < sizeof(struct load_command) ||
            !sb_range_ok(p, lc->cmdsize, cmds_end)) {
            return SB_MACHO_PATCH_ERR_NOT_MACHO;
        }
        switch (lc->cmd) {
            case LC_SEGMENT_64: {
                if (lc->cmdsize < sizeof(struct segment_command_64)) {
                    return SB_MACHO_PATCH_ERR_NOT_MACHO;
                }
                struct segment_command_64 *seg = (struct segment_command_64 *)lc;
                seg_count++;
                if (strncmp(seg->segname, "__PAGEZERO", 16) == 0) {
                    pagezero_cmd = seg;
                }
                if (seg->fileoff >= cmds_end && (size_t)seg->fileoff < free_end) {
                    free_end = (size_t)seg->fileoff;
                }
                uint8_t *section_ptr = (uint8_t *)seg + sizeof(struct segment_command_64);
                for (uint32_t s = 0; s < seg->nsects; s++) {
                    if (!sb_range_ok((size_t)(section_ptr - base), sizeof(struct section_64),
                                     p + lc->cmdsize)) {
                        return SB_MACHO_PATCH_ERR_NOT_MACHO;
                    }
                    struct section_64 *sect = (struct section_64 *)section_ptr;
                    if (sect->offset != 0 && (size_t)sect->offset < cmds_end) {
                        // section 数据落在加载命令区里，文件已损坏。
                        return SB_MACHO_PATCH_ERR_NOT_MACHO;
                    }
                    // 注意用 >=：section 紧贴加载命令区末尾时空闲就是 0，
                    // 用 > 会漏掉这个界，导致新命令盖掉 section 数据。
                    if (sect->offset >= cmds_end && (size_t)sect->offset < free_end) {
                        free_end = (size_t)sect->offset;
                    }
                    section_ptr += sizeof(struct section_64);
                }
                break;
            }
            case LC_ENCRYPTION_INFO:
            case LC_ENCRYPTION_INFO_64: {
                // encryption_command(_64) 的 cryptid 在命令头后第 16 字节。
                if (lc->cmdsize < 20) {
                    return SB_MACHO_PATCH_ERR_NOT_MACHO;
                }
                uint32_t cryptid = *(uint32_t *)(base + p + 16);
                if (cryptid != 0) {
                    return SB_MACHO_PATCH_ERR_ENCRYPTED;
                }
                break;
            }
            case LC_DYLD_CHAINED_FIXUPS: {
                if (lc->cmdsize < sizeof(struct linkedit_data_command)) {
                    return SB_MACHO_PATCH_ERR_NOT_MACHO;
                }
                fixups_cmd = (struct linkedit_data_command *)lc;
                break;
            }
            case LC_LOAD_DYLINKER: {
                has_dylinker = 1;
                dylinker_off = p;
                dylinker_size = lc->cmdsize;
                break;
            }
            case LC_MAIN: {
                // 0.2.16：只记第一条；多条 LC_MAIN 是损坏文件，
                // 打完校验（LC_MAIN 须已去掉）会拦。
                if (lc_main_size == 0) {
                    lc_main_off = p;
                    lc_main_size = lc->cmdsize;
                }
                break;
            }
            case LC_ID_DYLIB: {
                has_id_dylib = 1;
                break;
            }
            case LC_LOAD_DYLIB:
            case LC_LOAD_WEAK_DYLIB:
            case LC_REEXPORT_DYLIB: {
                if (lc->cmdsize >= sizeof(struct dylib_command)) {
                    struct dylib_command *dc = (struct dylib_command *)lc;
                    uint32_t name_off = dc->dylib.name.offset;
                    if (name_off < lc->cmdsize) {
                        const char *name = (const char *)base + p + name_off;
                        size_t max_len = (size_t)lc->cmdsize - name_off;
                        if (memchr(name, '\0', max_len) != NULL &&
                            strcmp(name, hooks_path) == 0) {
                            has_hooks_dylib = 1;
                        }
                    }
                }
                break;
            }
            case LC_RPATH: {
                if (lc->cmdsize >= sizeof(struct rpath_command)) {
                    struct rpath_command *rc = (struct rpath_command *)lc;
                    uint32_t path_off = rc->path.offset;
                    if (path_off < lc->cmdsize) {
                        const char *rpath = (const char *)base + p + path_off;
                        size_t max_len = (size_t)lc->cmdsize - path_off;
                        if (memchr(rpath, '\0', max_len) != NULL) {
                            if (strcmp(rpath, kSBRPathTweaks) == 0) {
                                has_rpath_tweaks = 1;
                            }
                            if (strcmp(rpath, kSBRPathLoader) == 0) {
                                has_rpath_loader = 1;
                            }
                        }
                    }
                }
                break;
            }
            default:
                break;
        }
        p += lc->cmdsize;
    }
    if (p != cmds_end) {
        return SB_MACHO_PATCH_ERR_NOT_MACHO;
    }

    // ---- 链式修正段数校验：fixups 数据里的段数须等于实际段数。----
    // 0.2.5（对齐 LiveContainer）：不一致只置标记、继续打补丁与签名，不再当安装失败；
    // iOS 27 上 dyld 加载时会按原文报错（SBGuestEntry.dlopenGuest 会把原文带出来），
    // v1 没有 dyld 内部绕过。标记经 seg_mismatch_out 交给调用方记在安装记录里。
    if (fixups_cmd != NULL) {
        uint32_t dataoff = fixups_cmd->dataoff;
        uint32_t datasize = fixups_cmd->datasize;
        if (!sb_range_ok(dataoff, datasize, size) ||
            datasize < sizeof(struct sb_chained_fixups_header)) {
            return SB_MACHO_PATCH_ERR_NOT_MACHO;
        }
        struct sb_chained_fixups_header *fixups_header =
            (struct sb_chained_fixups_header *)(base + dataoff);
        uint32_t starts_off = fixups_header->starts_offset;
        if (!sb_range_ok((size_t)dataoff + starts_off, sizeof(uint32_t), size)) {
            return SB_MACHO_PATCH_ERR_NOT_MACHO;
        }
        uint32_t starts_seg_count = *(uint32_t *)(base + dataoff + starts_off);
        if (starts_seg_count != seg_count) {
            if (seg_mismatch_out) {
                *seg_mismatch_out = 1;
            }
        }
    }

    // ---- 去掉 LC_MAIN（0.2.16）：LC_MAIN 是主程序入口命令，dylib 带它
    // dyld 不认（0.2.15 真机：execSeg 修好后 dlopen 仍报 code signature
    // invalid，errno 从 85 变成 1；同一份日志里客 dylib 带 LC_MAIN=在，
    // 宿主自带 dylib 都没有 LC_MAIN 且能正常加载）。后面的命令整体前移，
    // ncmds/sizeofcmds 跟着减；空出的尾部清零（不留旧命令残影）。
    // 入口偏移不丢：调用方在打补丁前用 SBMachOEntryOffset 读出、存进安装
    // 记录，加载器跳入客 main 时从记录里取（见 SBGuestBootstrap）。
    // dylinker 在 LC_MAIN 之后时它的偏移跟着减（一般在前，防御性处理）；
    // pagezero_cmd 是指向命令区的指针，第二遍改 __PAGEZERO 时还要用，
    // LC_MAIN 在它之前时指针要跟着减（实践中 __PAGEZERO 总是第一条段命令、
    // LC_MAIN 在后，这里是不靠顺序假设的防御）；fixups_cmd 只在上面
    // 的校验里用、去掉之后不再用，不用调。
    if (lc_main_size != 0) {
        size_t tail_off = lc_main_off + lc_main_size;
        size_t tail_len = cmds_end - tail_off;
        memmove(base + lc_main_off, base + tail_off, tail_len);
        memset(base + cmds_end - lc_main_size, 0, lc_main_size);
        header->ncmds -= 1;
        header->sizeofcmds -= lc_main_size;
        if (has_dylinker && dylinker_off > lc_main_off) {
            dylinker_off -= lc_main_size;
        }
        if (pagezero_cmd != NULL && (uint8_t *)pagezero_cmd >= base + lc_main_off) {
            pagezero_cmd = (struct segment_command_64 *)((uint8_t *)pagezero_cmd - lc_main_size);
        }
    }

    // ---- 第二遍：改文件头与 __PAGEZERO。----
    if (header->filetype == MH_EXECUTE) {
        header->filetype = MH_DYLIB;
    }
    header->flags &= ~MH_PIE;
    header->flags |= MH_NO_REEXPORTED_DYLIBS;
    if (((uint32_t)header->cpusubtype & ~0x80000000u) == (uint32_t)CPU_SUBTYPE_ARM64E) {
        header->cpusubtype |= CPU_SUBTYPE_LIB64;
    }
    if (pagezero_cmd != NULL) {
        pagezero_cmd->vmaddr = SB_MACHO_PATCH_PAGEZERO_VMADDR;
        pagezero_cmd->vmsize = SB_MACHO_PATCH_PAGEZERO_VMSIZE;
    }

    // ---- 插 LC_ID_DYLIB（LiveContainer 同款，0.2.5 新增）：放加载命令最前，
    // install name 取可执行文件名；UE3 类游戏需要它在最前面。
    // 空间不足时复用 LC_LOAD_DYLINKER 的槽位（名字截断放下）；两种都放不下就跳过，
    // 不报错——与 LC 一致，LC_ID_DYLIB 是尽力而为。
    // 注意：前插会让已有的加载命令整体后移，dylinker_off 是偏移量，要跟着加 id_needed。
    if (!has_id_dylib && id_name != NULL && id_name[0] != '\0') {
        uint32_t id_needed = sb_align_up_u32(
            (uint32_t)sizeof(struct dylib_command) + (uint32_t)strlen(id_name) + 1, 8);
        size_t cmds_end_now = sizeof(struct mach_header_64) + header->sizeofcmds;
        size_t slack_now = (free_end > cmds_end_now) ? (free_end - cmds_end_now) : 0;
        if (slack_now >= id_needed) {
            memmove(base + sizeof(struct mach_header_64) + id_needed,
                    base + sizeof(struct mach_header_64), header->sizeofcmds);
            sb_write_id_dylib_command(base + sizeof(struct mach_header_64), id_needed, id_name);
            header->ncmds += 1;
            header->sizeofcmds += id_needed;
            if (has_dylinker) {
                dylinker_off += id_needed;
            }
        } else if (has_dylinker && dylinker_size > (uint32_t)sizeof(struct dylib_command)) {
            // 复用 LC_LOAD_DYLINKER 的槽位：名字截断放下（与 LiveContainer 一致，
            // 它不要求槽位放得下完整名字——nameSize = 槽位 - 结构体，截断后末字节补 NUL；
            // 只要求槽位比结构体大，至少留 1 字节给名字）。
            uint8_t *slot = base + dylinker_off;
            memset(slot, 0, dylinker_size);
            struct dylib_command *dc = (struct dylib_command *)slot;
            dc->cmd = LC_ID_DYLIB;
            dc->cmdsize = dylinker_size;
            dc->dylib.name.offset = (uint32_t)sizeof(struct dylib_command);
            dc->dylib.timestamp = 2;
            dc->dylib.current_version = 0x10000;
            dc->dylib.compatibility_version = 0x10000;
            uint32_t name_room = dylinker_size - (uint32_t)sizeof(struct dylib_command);
            if (name_room > 0) {
                size_t copy_len = strlen(id_name);
                if (copy_len > (size_t)name_room - 1) {
                    copy_len = (size_t)name_room - 1;
                }
                memcpy(slot + sizeof(struct dylib_command), id_name, copy_len);
                slot[sizeof(struct dylib_command) + copy_len] = '\0';
            }
            // ncmds/sizeofcmds 不变（同槽位、同大小）。
            // 关键：dylinker 槽已被 ID 命令占了，后面的 LC_LOAD_DYLIB 注入
            // 不能再复用它（否则会把刚写的 ID 命令盖掉），所以 has_dylinker 清零。
            has_dylinker = 0;
        }
    }

    // ---- 注入 LC_LOAD_DYLIB + 补 LC_RPATH（已有的不重复加）。----
    // 先算总账：dylib 与缺失的 rpath 共要多少空闲空间，再选落位方式——
    // dylib 若先占了末尾空闲，rpath 可能没地方放，所以不能只按 dylib 一项决策。
    size_t cmds_end_now = sizeof(struct mach_header_64) + header->sizeofcmds;
    size_t slack = (free_end > cmds_end_now) ? (free_end - cmds_end_now) : 0;
    uint32_t dylib_needed = 0;
    if (!has_hooks_dylib) {
        dylib_needed = sb_align_up_u32(
            (uint32_t)sizeof(struct dylib_command) + (uint32_t)strlen(hooks_path) + 1, 8);
    }
    uint32_t rpaths_needed = 0;
    if (!has_rpath_tweaks) {
        rpaths_needed += sb_align_up_u32(
            (uint32_t)sizeof(struct rpath_command) + (uint32_t)strlen(kSBRPathTweaks) + 1, 8);
    }
    if (!has_rpath_loader) {
        rpaths_needed += sb_align_up_u32(
            (uint32_t)sizeof(struct rpath_command) + (uint32_t)strlen(kSBRPathLoader) + 1, 8);
    }
    if (!has_hooks_dylib) {
        if (slack >= (size_t)dylib_needed + rpaths_needed) {
            // 情形一：末尾空闲够放全部新命令，直接追加。
            sb_write_dylib_command(base + cmds_end_now, dylib_needed, hooks_path);
            header->ncmds += 1;
            header->sizeofcmds += dylib_needed;
        } else if (has_dylinker && dylinker_size >= dylib_needed && slack >= rpaths_needed) {
            // 情形二：LC_LOAD_DYLINKER 自身空间够放 dylib，原地替换（dyld 默认路径可缺省）；
            // rpath 用末尾空闲。注意 cmdsize 填整个槽位大小，不能只填 dylib 需要的长度，
            // 否则槽位尾部会残留 cmd=0 的垃圾命令。
            sb_write_dylib_command(base + dylinker_off, dylinker_size, hooks_path);
        } else if (has_dylinker && dylinker_size < dylib_needed &&
                   (size_t)(dylib_needed - dylinker_size) <= slack &&
                   slack - (dylib_needed - dylinker_size) >= rpaths_needed) {
            // 情形三：复用 LC_LOAD_DYLINKER 空间 + 一部分末尾空闲：
            // 把它后面的加载命令整体后移，腾出位置；余下空闲留给 rpath。
            uint32_t extra = dylib_needed - dylinker_size;
            size_t tail_off = dylinker_off + dylinker_size;
            size_t tail_len = cmds_end_now - tail_off;
            memmove(base + tail_off + extra, base + tail_off, tail_len);
            sb_write_dylib_command(base + dylinker_off, dylib_needed, hooks_path);
            header->sizeofcmds += extra;
        } else {
            return SB_MACHO_PATCH_ERR_NO_SPACE;
        }
    }

    // ---- 补 LC_RPATH（已有的不重复加；空间不足返回 NO_SPACE）。----
    if (!has_rpath_tweaks) {
        int32_t result = sb_add_rpath(base, header, free_end, kSBRPathTweaks);
        if (result != SB_MACHO_PATCH_OK) {
            return result;
        }
    }
    if (!has_rpath_loader) {
        int32_t result = sb_add_rpath(base, header, free_end, kSBRPathLoader);
        if (result != SB_MACHO_PATCH_OK) {
            return result;
        }
    }

    // ---- dylib 去重（LiveContainer 同款，0.2.5 新增）：重复的 LC_LOAD_DYLIB /
    // LC_LOAD_WEAK_DYLIB / LC_REEXPORT_DYLIB / LC_LOAD_UPWARD_DYLIB 改写为
    // 无效命令号 0x114515，dyld 会跳过。名字按字符串精确比对，命令格式不合法就跳过该条。
    {
        size_t count = header->ncmds;
        const char **seen = (const char **)malloc((count > 0 ? count : 1) * sizeof(char *));
        if (seen != NULL) {
            size_t seen_count = 0;
            size_t q = sizeof(struct mach_header_64);
            size_t cmds_end_now = sizeof(struct mach_header_64) + header->sizeofcmds;
            for (uint32_t i = 0; i < header->ncmds; i++) {
                if (!sb_range_ok(q, sizeof(struct load_command), cmds_end_now)) {
                    break;
                }
                struct load_command *lc = (struct load_command *)(base + q);
                if (lc->cmdsize < sizeof(struct load_command) ||
                    !sb_range_ok(q, lc->cmdsize, cmds_end_now)) {
                    break;
                }
                if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB ||
                    lc->cmd == LC_REEXPORT_DYLIB || lc->cmd == LC_LOAD_UPWARD_DYLIB) {
                    struct dylib_command *dc = (struct dylib_command *)lc;
                    uint32_t name_off = dc->dylib.name.offset;
                    if (name_off < lc->cmdsize) {
                        const char *name = (const char *)base + q + name_off;
                        size_t max_len = (size_t)lc->cmdsize - name_off;
                        if (memchr(name, '\0', max_len) != NULL) {
                            int dup = 0;
                            for (size_t k = 0; k < seen_count; k++) {
                                if (strcmp(name, seen[k]) == 0) {
                                    dup = 1;
                                    break;
                                }
                            }
                            if (dup) {
                                lc->cmd = 0x114515; // 无效命令号，dyld 会跳过
                            } else {
                                seen[seen_count++] = name;
                            }
                        }
                    }
                }
                q += lc->cmdsize;
            }
            free(seen);
        }
    }

    // ---- 打完校验（0.2.16）：filetype 须是 MH_DYLIB、LC_ID_DYLIB 在位
    // （id_name 给了时）、LC_MAIN 须已去掉。任一不符返回校验错，调用方
    // 不写回文件（SBMachOPatchExecutable 只在全部切片 OK 时写回）。
    // 注意：去重步骤把重复的 LC_LOAD_DYLIB 改写成无效命令号 0x114515，
    // 那不是 LC_ID_DYLIB/LC_MAIN，校验时跳过。
    {
        size_t q = sizeof(struct mach_header_64);
        size_t cmds_end_now = sizeof(struct mach_header_64) + header->sizeofcmds;
        int saw_id = 0, saw_main = 0;
        for (uint32_t i = 0; i < header->ncmds; i++) {
            if (!sb_range_ok(q, sizeof(struct load_command), cmds_end_now)) {
                return SB_MACHO_PATCH_ERR_VERIFY;
            }
            struct load_command *lc = (struct load_command *)(base + q);
            if (lc->cmdsize < sizeof(struct load_command) ||
                !sb_range_ok(q, lc->cmdsize, cmds_end_now)) {
                return SB_MACHO_PATCH_ERR_VERIFY;
            }
            if (lc->cmd == LC_ID_DYLIB) {
                saw_id = 1;
            }
            if (lc->cmd == LC_MAIN) {
                saw_main = 1;
            }
            q += lc->cmdsize;
        }
        if (header->filetype != MH_DYLIB) {
            return SB_MACHO_PATCH_ERR_VERIFY;
        }
        if (saw_main) {
            return SB_MACHO_PATCH_ERR_VERIFY;
        }
        if (id_name != NULL && id_name[0] != '\0' && !saw_id) {
            return SB_MACHO_PATCH_ERR_VERIFY;
        }
    }

    return SB_MACHO_PATCH_OK;
}

// 处理 fat 包：逐个处理其中的 arm64/arm64e 切片；任一切片失败则整体失败。
static int32_t sb_patch_fat(uint8_t *buffer, size_t size, const char *hooks_path,
                            const char *id_name, int *seg_mismatch_out) {
    if (size < sizeof(struct fat_header)) {
        return SB_MACHO_PATCH_ERR_NOT_MACHO;
    }
    struct fat_header *fat_header = (struct fat_header *)buffer;
    uint32_t nfat_arch = (uint32_t)OSSwapBigToHostInt32(fat_header->nfat_arch);
    if (!sb_range_ok(sizeof(struct fat_header),
                     (size_t)nfat_arch * sizeof(struct fat_arch), size)) {
        return SB_MACHO_PATCH_ERR_NOT_MACHO;
    }
    int saw_arm64 = 0;
    int saw_32bit = 0;
    for (uint32_t i = 0; i < nfat_arch; i++) {
        struct fat_arch *arch = (struct fat_arch *)(buffer + sizeof(struct fat_header) +
                                                    i * sizeof(struct fat_arch));
        cpu_type_t cputype = OSSwapBigToHostInt32(arch->cputype);
        uint32_t offset = (uint32_t)OSSwapBigToHostInt32(arch->offset);
        uint32_t arch_size = (uint32_t)OSSwapBigToHostInt32(arch->size);
        if (cputype == CPU_TYPE_ARM64) {
            saw_arm64 = 1;
            if (!sb_range_ok(offset, arch_size, size)) {
                return SB_MACHO_PATCH_ERR_NOT_MACHO;
            }
            int32_t result = sb_patch_thin_slice(buffer + offset, arch_size, hooks_path,
                                                 id_name, seg_mismatch_out);
            if (result != SB_MACHO_PATCH_OK) {
                return result;
            }
        } else if (cputype == CPU_TYPE_ARM) {
            saw_32bit = 1;
        }
    }
    if (!saw_arm64) {
        if (saw_32bit) {
            return SB_MACHO_PATCH_ERR_UNSUPPORTED_32BIT;
        }
        return SB_MACHO_PATCH_ERR_UNSUPPORTED_ARCH;
    }
    return SB_MACHO_PATCH_OK;
}

int32_t SBMachOPatchExecutable(const char *path, const char *hooks_dylib_path,
                               int *seg_mismatch_out) {
    if (path == NULL || hooks_dylib_path == NULL || hooks_dylib_path[0] == '\0') {
        return SB_MACHO_PATCH_ERR_NOT_MACHO;
    }
    if (seg_mismatch_out) {
        *seg_mismatch_out = 0;
    }
    // LC_ID_DYLIB 的 install name 取可执行文件名（basename）。
    const char *id_name = strrchr(path, '/');
    id_name = (id_name != NULL) ? id_name + 1 : path;
    size_t size = 0;
    uint8_t *buffer = sb_read_file(path, &size);
    if (buffer == NULL) {
        return SB_MACHO_PATCH_ERR_IO;
    }

    int32_t result = SB_MACHO_PATCH_ERR_NOT_MACHO;
    if (size >= sizeof(uint32_t)) {
        uint32_t magic = *(uint32_t *)buffer;
        if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
            result = sb_patch_fat(buffer, size, hooks_dylib_path, id_name, seg_mismatch_out);
        } else {
            result = sb_patch_thin_slice(buffer, size, hooks_dylib_path, id_name, seg_mismatch_out);
        }
    }

    // 全部切片成功才写回；任一失败文件原样不动。
    if (result == SB_MACHO_PATCH_OK) {
        if (!sb_write_file(path, buffer, size)) {
            result = SB_MACHO_PATCH_ERR_IO;
        }
    }
    free(buffer);
    return result;
}

// 给单个 Mach-O 文件的 arm64e 切片补 CPU_SUBTYPE_LIB64 标记（见头文件）。
// 只在内存里改、改了才写回；不是 arm64e / 已有 LIB64 / 不是 Mach-O 时不改不动。
int32_t SBMachOPatchARM64eFile(const char *path) {
    if (path == NULL) {
        return SB_MACHO_PATCH_ERR_NOT_MACHO;
    }
    size_t size = 0;
    uint8_t *buffer = sb_read_file(path, &size);
    if (buffer == NULL) {
        return SB_MACHO_PATCH_ERR_IO;
    }
    int changed = 0;
    int32_t result = SB_MACHO_PATCH_OK;
    if (size >= sizeof(uint32_t)) {
        uint32_t magic = *(uint32_t *)buffer;
        if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
            if (size < sizeof(struct fat_header)) {
                result = SB_MACHO_PATCH_ERR_NOT_MACHO;
            } else {
                struct fat_header *fat_header = (struct fat_header *)buffer;
                uint32_t nfat_arch = (uint32_t)OSSwapBigToHostInt32(fat_header->nfat_arch);
                if (!sb_range_ok(sizeof(struct fat_header),
                                 (size_t)nfat_arch * sizeof(struct fat_arch), size)) {
                    result = SB_MACHO_PATCH_ERR_NOT_MACHO;
                } else {
                    for (uint32_t i = 0; i < nfat_arch; i++) {
                        struct fat_arch *arch = (struct fat_arch *)(buffer +
                            sizeof(struct fat_header) + i * sizeof(struct fat_arch));
                        cpu_type_t cputype = OSSwapBigToHostInt32(arch->cputype);
                        cpu_subtype_t cpusubtype = OSSwapBigToHostInt32(arch->cpusubtype);
                        uint32_t offset = (uint32_t)OSSwapBigToHostInt32(arch->offset);
                        uint32_t arch_size = (uint32_t)OSSwapBigToHostInt32(arch->size);
                        if (cputype != CPU_TYPE_ARM64 || !sb_range_ok(offset, arch_size, size)) {
                            continue;
                        }
                        if (((uint32_t)cpusubtype & ~0x80000000u) != (uint32_t)CPU_SUBTYPE_ARM64E ||
                            (cpusubtype & CPU_SUBTYPE_LIB64) != 0) {
                            continue;
                        }
                        // 切片头与 fat 目录两处都要置位（fat 目录里是大端序）。
                        struct mach_header_64 *slice_header =
                            (struct mach_header_64 *)(buffer + offset);
                        slice_header->cpusubtype |= CPU_SUBTYPE_LIB64;
                        arch->cpusubtype = OSSwapHostToBigInt32(cpusubtype | CPU_SUBTYPE_LIB64);
                        changed = 1;
                    }
                }
            }
        } else if (magic == MH_MAGIC_64) {
            if (size < sizeof(struct mach_header_64)) {
                result = SB_MACHO_PATCH_ERR_NOT_MACHO;
            } else {
                struct mach_header_64 *header = (struct mach_header_64 *)buffer;
                if (header->cputype == CPU_TYPE_ARM64 &&
                    ((uint32_t)header->cpusubtype & ~0x80000000u) == (uint32_t)CPU_SUBTYPE_ARM64E &&
                    (header->cpusubtype & CPU_SUBTYPE_LIB64) == 0) {
                    header->cpusubtype |= CPU_SUBTYPE_LIB64;
                    changed = 1;
                }
            }
        }
        // 其他 magic（32 位、MH_MAGIC 等）不是目标：不改，不报错。
    }
    if (result == SB_MACHO_PATCH_OK && changed) {
        if (!sb_write_file(path, buffer, size)) {
            result = SB_MACHO_PATCH_ERR_IO;
        }
    }
    free(buffer);
    return result;
}

/// 一个 thin 切片里有没有 LC_ID_DYLIB（只认 64 位头；越界即判为无）。
static int sb_slice_has_id_dylib(const uint8_t *base, size_t size) {
    if (size < sizeof(struct mach_header_64)) {
        return 0;
    }
    if (*(const uint32_t *)base != MH_MAGIC_64) {
        return 0;
    }
    const struct mach_header_64 *header = (const struct mach_header_64 *)base;
    if (header->cputype != CPU_TYPE_ARM64) {
        return 0;
    }
    size_t offset = sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (!sb_range_ok(offset, 8, size)) {
            return 0;
        }
        uint32_t cmd = *(const uint32_t *)(base + offset);
        uint32_t cmdsize = *(const uint32_t *)(base + offset + 4);
        if (cmdsize < 8 || !sb_range_ok(offset, cmdsize, size)) {
            return 0;
        }
        if (cmd == LC_ID_DYLIB) {
            return 1;
        }
        offset += cmdsize;
    }
    return 0;
}

int SBMachOHasIDDylib(const char *path) {
    if (!path || !*path) {
        return 0;
    }
    size_t size = 0;
    uint8_t *buffer = sb_read_file(path, &size);
    if (!buffer) {
        return 0;
    }
    int result = 0;
    uint32_t magic = *(uint32_t *)buffer;
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        // fat 包：每个 arm64 切片都必须带 LC_ID_DYLIB。
        if (size >= sizeof(struct fat_header)) {
            uint32_t narch = OSSwapBigToHostInt32(((struct fat_header *)buffer)->nfat_arch);
            int arm64_slices = 0;
            int ok = 1;
            for (uint32_t i = 0; i < narch; i++) {
                size_t arch_off = sizeof(struct fat_header) + (size_t)i * sizeof(struct fat_arch);
                if (!sb_range_ok(arch_off, sizeof(struct fat_arch), size)) {
                    ok = 0;
                    break;
                }
                const struct fat_arch *arch = (const struct fat_arch *)(buffer + arch_off);
                uint32_t cputype = OSSwapBigToHostInt32(arch->cputype);
                if (cputype != CPU_TYPE_ARM64) {
                    continue;
                }
                uint32_t off = OSSwapBigToHostInt32(arch->offset);
                uint32_t arch_size = OSSwapBigToHostInt32(arch->size);
                if (!sb_range_ok(off, arch_size, size)) {
                    ok = 0;
                    break;
                }
                arm64_slices++;
                if (!sb_slice_has_id_dylib(buffer + off, arch_size)) {
                    ok = 0;
                    break;
                }
            }
            result = (ok && arm64_slices > 0) ? 1 : 0;
        }
    } else if (magic == MH_MAGIC_64) {
        result = sb_slice_has_id_dylib(buffer, size);
    }
    free(buffer);
    return result;
}

/// 一个 thin 切片里 LC_MAIN 的 entryoff（只认 64 位头；越界/无 LC_MAIN 返回 0）。
/// entry_point_command 布局：cmd(4) cmdsize(4) entryoff(8) stacksize(8)。
static int sb_slice_entry_offset(const uint8_t *base, size_t size, uint64_t *entryoff_out) {
    if (size < sizeof(struct mach_header_64)) {
        return 0;
    }
    if (*(const uint32_t *)base != MH_MAGIC_64) {
        return 0;
    }
    const struct mach_header_64 *header = (const struct mach_header_64 *)base;
    if (header->cputype != CPU_TYPE_ARM64) {
        return 0;
    }
    size_t offset = sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (!sb_range_ok(offset, 8, size)) {
            return 0;
        }
        uint32_t cmd = *(const uint32_t *)(base + offset);
        uint32_t cmdsize = *(const uint32_t *)(base + offset + 4);
        if (cmdsize < 8 || !sb_range_ok(offset, cmdsize, size)) {
            return 0;
        }
        if (cmd == LC_MAIN) {
            if (cmdsize < sizeof(struct entry_point_command)) {
                return 0;
            }
            *entryoff_out = *(const uint64_t *)(base + offset + 8);
            return 1;
        }
        offset += cmdsize;
    }
    return 0;
}

int SBMachOEntryOffset(const char *path, uint64_t *entryoffOut) {
    if (path == NULL || entryoffOut == NULL) {
        return 0;
    }
    *entryoffOut = 0;
    size_t size = 0;
    uint8_t *buffer = sb_read_file(path, &size);
    if (buffer == NULL || size < sizeof(uint32_t)) {
        free(buffer); // 1–3 字节的文件也到不了 Mach-O，直接返回 0
        return 0;
    }
    int found = 0;
    uint64_t entryoff = 0;
    uint32_t magic = *(uint32_t *)buffer;
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        // fat 包：取 arm64e 优先、其次首个 arm64 切片（与 SBGuestEntry
        // 的取片偏好一致——加载器只用这一个切片的 entryoff 跳入口）。
        if (size >= sizeof(struct fat_header)) {
            struct fat_header *fat_header = (struct fat_header *)buffer;
            uint32_t nfat_arch = (uint32_t)OSSwapBigToHostInt32(fat_header->nfat_arch);
            uint32_t arm64_off = 0, arm64_size = 0;
            int saw_arm64 = 0;
            for (uint32_t i = 0; i < nfat_arch; i++) {
                size_t arch_off = sizeof(struct fat_header) + (size_t)i * sizeof(struct fat_arch);
                if (!sb_range_ok(arch_off, sizeof(struct fat_arch), size)) {
                    break;
                }
                struct fat_arch *arch = (struct fat_arch *)(buffer + arch_off);
                cpu_type_t cputype = OSSwapBigToHostInt32(arch->cputype);
                cpu_subtype_t cpusubtype = OSSwapBigToHostInt32(arch->cpusubtype);
                uint32_t offset = (uint32_t)OSSwapBigToHostInt32(arch->offset);
                uint32_t arch_size = (uint32_t)OSSwapBigToHostInt32(arch->size);
                if (cputype != CPU_TYPE_ARM64 || !sb_range_ok(offset, arch_size, size)) {
                    continue;
                }
                if (((uint32_t)cpusubtype & ~0x80000000u) == (uint32_t)CPU_SUBTYPE_ARM64E) {
                    arm64_off = offset;
                    arm64_size = arch_size;
                    saw_arm64 = 1;
                    break;
                }
                if (!saw_arm64) {
                    arm64_off = offset;
                    arm64_size = arch_size;
                    saw_arm64 = 1;
                }
            }
            if (saw_arm64) {
                found = sb_slice_entry_offset(buffer + arm64_off, arm64_size, &entryoff);
            }
        }
    } else if (magic == MH_MAGIC_64) {
        found = sb_slice_entry_offset(buffer, size, &entryoff);
    }
    free(buffer);
    if (found) {
        *entryoffOut = entryoff;
        return 1;
    }
    return 0;
}
