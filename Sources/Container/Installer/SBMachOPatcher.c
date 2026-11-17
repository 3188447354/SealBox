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
static int32_t sb_patch_thin_slice(uint8_t *base, size_t size, const char *hooks_path) {
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
    int has_rpath_tweaks = 0;
    int has_rpath_loader = 0;
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
            return SB_MACHO_PATCH_ERR_SEG_COUNT_MISMATCH;
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

    return SB_MACHO_PATCH_OK;
}

// 处理 fat 包：逐个处理其中的 arm64/arm64e 切片；任一切片失败则整体失败。
static int32_t sb_patch_fat(uint8_t *buffer, size_t size, const char *hooks_path) {
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
            int32_t result = sb_patch_thin_slice(buffer + offset, arch_size, hooks_path);
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

int32_t SBMachOPatchExecutable(const char *path, const char *hooks_dylib_path) {
    if (path == NULL || hooks_dylib_path == NULL || hooks_dylib_path[0] == '\0') {
        return SB_MACHO_PATCH_ERR_NOT_MACHO;
    }
    size_t size = 0;
    uint8_t *buffer = sb_read_file(path, &size);
    if (buffer == NULL) {
        return SB_MACHO_PATCH_ERR_IO;
    }

    int32_t result = SB_MACHO_PATCH_ERR_NOT_MACHO;
    if (size >= sizeof(uint32_t)) {
        uint32_t magic = *(uint32_t *)buffer;
        if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
            result = sb_patch_fat(buffer, size, hooks_dylib_path);
        } else {
            result = sb_patch_thin_slice(buffer, size, hooks_dylib_path);
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
