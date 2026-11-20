// SBChainedFixupRebind.m — 链式修正感知的 GOT 重绑（0.2.28）。
//
// 实证布局（原型 0228，宿主二进制 Xcode 26.2 产物，DYLD_CHAINED_PTR_64_OFFSET）：
//   链项 8 字节：bit63 = bind 标志（1=bind，0=rebase）；bits 52-62 = next
//     （11 位，单位 8 字节）；bind 时 bits 0-15 = import 序号、bits 16-23 = addend；
//     rebase 时 bits 0-51 = 目标偏移。
//   import 项：DYLD_CHAINED_IMPORT 为 4 字节，ADDEND/ADDEND64 为 8 字节；
//     byte0 = lib 序号，bytes1-2 的 u16 = 符号池内字节偏移 × 2。
//
// 关键：链式修正的原始链项只在磁盘文件里——dlopen 后 dyld 已把 __got 槽
// 写成解析后的函数地址，编码（bind/next/序号）被覆盖，内存里走不了链。
// 所以链式路读磁盘文件找槽的文件偏移，再按段 vmaddr+slide 换算成运行时地址
// 改写。传统路不依赖槽位当前值（按间接符号表按名找槽号），可直接读内存。
// 安全：只在 import 名与目标符号逐字相等时改写；布局对不上（名解不出来）
// 时找不到槽，返回 NO 走护栏，不会误改别的槽。
#import "SBChainedFixupRebind.h"

#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <stdbool.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

#import "litehook.h"
#import "SBDiagLog.h"

// os_thread_self_tpro_is_writeable 在 litehook.c 里有定义、头文件未导出，
// 这里自行声明（与 litehook_rebind_symbol_in_section 同款用法）。
extern bool os_thread_self_tpro_is_writeable(void);

// 0.2.28 fixup 1（根因修，首版 7ff45f5 的致命 bug）：
//   SDK 的 LC_DYLD_CHAINED_FIXUPS 自带 LC_REQ_DYLD 位，即 0x80000034
//   （同款：LC_DYLD_INFO_ONLY = 0x80000022，见 ZSign/common/mach-o.h:217；
//   LiveContainer 的 LCMachOUtils.m:194 对此是拿原始 cmd 直接比常量）。
//   首版这里掩了 cmd（& 0x7FFFFFFF）却拿掩过的 cmd 去比没掩的常量——
//   掩过的值最大 0x7FFFFFFF，永不可能等于 0x80000034，编译期即可判定
//   为假：Clang 把分支折掉，hasChainedFixups 恒为 NO，链接器再把整条
//   链式路（SBRebindChained＋SBArm64SliceOffset＋SBFileOffsetToRuntimeAddress
//   及其全部字串）当死代码消除。实证：首版 IPA 的 dSYM 里无 SBRebindChained，
//   二进制里无任一“链式重绑”字串；运行时所有链式修正镜像（现代 Xcode
//   产物全是）都会落到传统路、找不到 __la/__nl_symbol_ptr、经护栏干净
//   失败——不闪退，但 SwiftUI 客永远嵌不进去。
//   铁律：掩 cmd 的同时必须掩常量，两边都掩（或两边都不掩）。分型器
//   SBGuestUIClassifier.m 用字面量 0x34 是对的，不受影响。
static BOOL SBIsChainedFixupsCommand(uint32_t rawCmd) {
    return (rawCmd & 0x7FFFFFFF) == (LC_DYLD_CHAINED_FIXUPS & 0x7FFFFFFF);
}

#define SB_MAX_SEGMENTS 16
#define SB_MAX_CHAIN_STEPS 100000

typedef struct {
    char segname[17];
    uint64_t vmaddr;
    uint64_t fileoff;
    uint64_t filesize;
} SBSegmentInfo;

typedef struct {
    const struct mach_header_64 *header;
    uintptr_t slide;
    SBSegmentInfo segments[SB_MAX_SEGMENTS];
    uint32_t segmentCount;
    uint32_t symoff;
    uint32_t nsyms;
    uint32_t stroff;
    uint32_t strsize;
    uint32_t indirectSymoff;
    uint32_t nindirectSyms;
    BOOL hasChainedFixups;
    uint64_t linkeditVmaddr;
    uint64_t linkeditFileoff;
} SBImageLayout;

/// 把文件偏移（切片内相对偏移）换算成运行时地址（段 vmaddr + slide + 段内偏移）。
static uintptr_t SBFileOffsetToRuntimeAddress(SBImageLayout *layout,
                                             uint64_t fileoff) {
    for (uint32_t i = 0; i < layout->segmentCount; i++) {
        SBSegmentInfo *seg = &layout->segments[i];
        if (fileoff >= seg->fileoff &&
            fileoff < seg->fileoff + seg->filesize) {
            return (uintptr_t)(seg->vmaddr + layout->slide +
                               (fileoff - seg->fileoff));
        }
    }
    return 0;
}

/// 把 __LINKEDIT 内文件偏移换算成运行时地址（符号表/字符串表都在此段）。
static const uint8_t *SBLinkeditPointer(SBImageLayout *layout,
                                        uint64_t fileoff) {
    if (fileoff < layout->linkeditFileoff) {
        return NULL;
    }
    uintptr_t addr = (uintptr_t)(layout->linkeditVmaddr + layout->slide +
                                 (fileoff - layout->linkeditFileoff));
    return (const uint8_t *)addr;
}

/// 读镜像头里的加载命令，填布局。只认 64 位 Mach-O；非法返回 NO。
static BOOL SBParseImageLayout(const struct mach_header *header,
                               SBImageLayout *layout) {
    memset(layout, 0, sizeof(*layout));
    if (!header || header->magic != MH_MAGIC_64) {
        return NO;
    }
    const struct mach_header_64 *header64 = (const struct mach_header_64 *)header;
    layout->header = header64;
    const struct load_command *lc =
        (const struct load_command *)((const uint8_t *)header + sizeof(*header64));
    uintptr_t firstSegVmaddr = 0;
    BOOL haveFirstSeg = NO;
    for (uint32_t i = 0; i < header64->ncmds; i++) {
        uint32_t baseCmd = lc->cmd & 0x7FFFFFFF; // 去 LC_REQ_DYLD 位
        if (baseCmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg =
                (const struct segment_command_64 *)lc;
            if (!haveFirstSeg) {
                firstSegVmaddr = (uintptr_t)seg->vmaddr;
                haveFirstSeg = YES;
            }
            if (layout->segmentCount < SB_MAX_SEGMENTS) {
                SBSegmentInfo *info = &layout->segments[layout->segmentCount++];
                memcpy(info->segname, seg->segname, 16);
                info->segname[16] = '\0';
                info->vmaddr = seg->vmaddr;
                info->fileoff = seg->fileoff;
                info->filesize = seg->filesize;
            }
            if (strncmp(seg->segname, "__LINKEDIT", 16) == 0) {
                layout->linkeditVmaddr = seg->vmaddr;
                layout->linkeditFileoff = seg->fileoff;
            }
        } else if (baseCmd == LC_SYMTAB) {
            const struct symtab_command *symtab =
                (const struct symtab_command *)lc;
            layout->symoff = symtab->symoff;
            layout->nsyms = symtab->nsyms;
            layout->stroff = symtab->stroff;
            layout->strsize = symtab->strsize;
        } else if (baseCmd == LC_DYSYMTAB) {
            const struct dysymtab_command *dysymtab =
                (const struct dysymtab_command *)lc;
            layout->indirectSymoff = dysymtab->indirectsymoff;
            layout->nindirectSyms = dysymtab->nindirectsyms;
        } else if (SBIsChainedFixupsCommand(lc->cmd)) {
            layout->hasChainedFixups = YES;
        }
        if (lc->cmdsize == 0) {
            return NO;
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    if (!haveFirstSeg) {
        return NO;
    }
    layout->slide = (uintptr_t)header - firstSegVmaddr;
    return YES;
}

/// 改写一个 GOT 槽（8 字节指针）。页先放开写权限（TPRO dance 同 litehook），
// 写完不恢复保护（与 _litehook_rebind_symbol_in_section 一致）。
static BOOL SBRewriteSlot(uintptr_t slotAddress, void *replacement) {
    if (slotAddress == 0 || replacement == NULL) {
        return NO;
    }
    vm_size_t pageSize = (vm_size_t)vm_page_size;
    vm_address_t page = (vm_address_t)(slotAddress & ~(uintptr_t)(pageSize - 1));
#if __arm64__
    BOOL needsTPRORevert = NO;
    if (os_tpro_is_supported()) {
        if (!os_thread_self_tpro_is_writeable()) {
            os_thread_self_restrict_tpro_to_rw();
            needsTPRORevert = YES;
        }
    }
#endif
    kern_return_t kr = vm_protect(mach_task_self(), page, pageSize, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
#if __arm64__
        if (needsTPRORevert) {
            os_thread_self_restrict_tpro_to_ro();
        }
#endif
        return NO;
    }
    *(void **)slotAddress = replacement;
#if __arm64__
    if (needsTPRORevert) {
        os_thread_self_restrict_tpro_to_ro();
    }
#endif
    return YES;
}

#pragma mark - 链式修正路（读磁盘文件）

/// 在磁盘文件里找 arm64 切片偏移（fat 包取 arm64 切片；薄包为 0）。
/// 失败返回 NO（baseOffset 不动）。
static BOOL SBArm64SliceOffset(FILE *file, uint64_t *baseOffsetOut) {
    uint32_t magic = 0;
    if (fread(&magic, sizeof(magic), 1, file) != 1) {
        return NO;
    }
    if (magic != 0xCAFEBABE && magic != 0xBEBAFECA) {
        // 薄包：回卷到文件头。
        if (fseek(file, 0, SEEK_SET) != 0) {
            return NO;
        }
        *baseOffsetOut = 0;
        return YES;
    }
    uint32_t nfat = 0;
    BOOL swapped = (magic == 0xBEBAFECA);
    fseek(file, 4, SEEK_SET);
    if (fread(&nfat, sizeof(nfat), 1, file) != 1) {
        return NO;
    }
    if (swapped) {
        nfat = __builtin_bswap32(nfat);
    }
    for (uint32_t i = 0; i < nfat; i++) {
        uint32_t cputype = 0, offset = 0;
        fseek(file, 8 + i * 20, SEEK_SET);
        if (fread(&cputype, sizeof(cputype), 1, file) != 1) {
            return NO;
        }
        if (swapped) {
            cputype = __builtin_bswap32(cputype);
        }
        fseek(file, 8 + i * 20 + 8, SEEK_SET);
        if (fread(&offset, sizeof(offset), 1, file) != 1) {
            return NO;
        }
        if (swapped) {
            offset = __builtin_bswap32(offset);
        }
        if (cputype == 0x0100000C) { // CPU_TYPE_ARM64
            *baseOffsetOut = offset;
            return YES;
        }
    }
    return NO;
}

/// 链式修正路：读磁盘文件，走链按 import 名找槽的文件偏移，换算成运行时地址
/// 改写。返回改写的槽数。layout 只用来做文件偏移→运行时地址换算与日志。
static uint32_t SBRebindChained(SBImageLayout *layout,
                                NSString *execPath,
                                const char *symbolName,
                                void *replacement) {
    FILE *file = fopen([execPath UTF8String], "rb");
    if (!file) {
        return 0;
    }
    uint64_t baseOffset = 0;
    if (!SBArm64SliceOffset(file, &baseOffset)) {
        fclose(file);
        return 0;
    }
    uint32_t magic = 0;
    fseek(file, (long)baseOffset, SEEK_SET);
    if (fread(&magic, sizeof(magic), 1, file) != 1 || magic != 0xFEEDFACF) {
        fclose(file);
        return 0;
    }
    uint32_t ncmds = 0;
    fseek(file, (long)(baseOffset + 16), SEEK_SET);
    if (fread(&ncmds, sizeof(ncmds), 1, file) != 1) {
        fclose(file);
        return 0;
    }
    // 找 LC_DYLD_CHAINED_FIXUPS 的 dataoff/datasize。
    uint32_t chainedDataoff = 0, chainedDatasize = 0;
    uint64_t cursor = baseOffset + 32;
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = 0, cmdsize = 0;
        fseek(file, (long)cursor, SEEK_SET);
        if (fread(&cmd, sizeof(cmd), 1, file) != 1 ||
            fread(&cmdsize, sizeof(cmdsize), 1, file) != 1) {
            fclose(file);
            return 0;
        }
        if (SBIsChainedFixupsCommand(cmd)) {
            fseek(file, (long)(cursor + 8), SEEK_SET);
            if (fread(&chainedDataoff, sizeof(chainedDataoff), 1, file) != 1 ||
                fread(&chainedDatasize, sizeof(chainedDatasize), 1, file) != 1) {
                fclose(file);
                return 0;
            }
            break;
        }
        if (cmdsize == 0) {
            break;
        }
        cursor += cmdsize;
    }
    if (chainedDataoff == 0 || chainedDatasize < 28) {
        fclose(file);
        return 0;
    }
    // 把整段 fixup 数据读进内存（通常 < 100KB）。
    uint8_t *fixups = (uint8_t *)malloc(chainedDatasize);
    if (!fixups) {
        fclose(file);
        return 0;
    }
    fseek(file, (long)(baseOffset + chainedDataoff), SEEK_SET);
    if (fread(fixups, 1, chainedDatasize, file) != chainedDatasize) {
        free(fixups);
        fclose(file);
        return 0;
    }
    // dyld_chained_fixups_header（7 个 u32）。
    uint32_t startsOff = *(const uint32_t *)(fixups + 4);
    uint32_t importsOff = *(const uint32_t *)(fixups + 8);
    uint32_t symbolsOff = *(const uint32_t *)(fixups + 12);
    uint32_t importsCount = *(const uint32_t *)(fixups + 16);
    uint32_t importsFormat = *(const uint32_t *)(fixups + 20);
    uint32_t symbolsFormat = *(const uint32_t *)(fixups + 24);
    uint32_t rewrote = 0;
    do {
        if (symbolsFormat != 0) {
            SBDiagLogLine(@"链式重绑：符号池是压缩格式，不支持");
            break;
        }
        uint32_t importEntrySize = 0;
        if (importsFormat == 1) { // DYLD_CHAINED_IMPORT
            importEntrySize = 4;
        } else if (importsFormat == 2 || importsFormat == 3) { // ADDEND / ADDEND64
            importEntrySize = 8;
        } else {
            SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：import 格式 %u 不支持",
                            importsFormat] UTF8String]);
            break;
        }
        if (importsOff + importsCount * importEntrySize > chainedDatasize ||
            symbolsOff >= chainedDatasize) {
            break;
        }
        const uint8_t *imports = fixups + importsOff;
        const uint8_t *pool = fixups + symbolsOff;
        size_t poolSize = chainedDatasize - symbolsOff;
        // 找目标符号的 import 序号（名逐字相等才认）。
        int32_t targetOrdinal = -1;
        for (uint32_t i = 0; i < importsCount; i++) {
            uint32_t v = *(const uint32_t *)(imports + i * importEntrySize);
            uint32_t nameByteOff = ((v >> 8) & 0xFFFF) / 2;
            if (nameByteOff >= poolSize) {
                continue;
            }
            const char *name = (const char *)(pool + nameByteOff);
            size_t maxLen = poolSize - nameByteOff;
            if (strnlen(name, maxLen) >= maxLen) {
                continue;
            }
            if (strcmp(name, symbolName) == 0) {
                targetOrdinal = (int32_t)i;
                break;
            }
        }
        if (targetOrdinal < 0) {
            break;
        }
        // 走链：dyld_chained_starts_in_image。
        if (startsOff + 4 > chainedDatasize) {
            break;
        }
        uint32_t segCount = *(const uint32_t *)(fixups + startsOff);
        for (uint32_t si = 0; si < segCount; si++) {
            if (startsOff + 4 + si * 4 + 4 > chainedDatasize) {
                break;
            }
            uint32_t segInfoOff = *(const uint32_t *)(fixups + startsOff + 4 + si * 4);
            if (segInfoOff == 0) {
                continue; // 该段无 fixup。
            }
            const uint8_t *segStarts = fixups + startsOff + segInfoOff;
            if ((size_t)(segStarts - fixups) + 22 > chainedDatasize) {
                continue;
            }
            uint16_t pageSize = *(const uint16_t *)(segStarts + 4);
            uint16_t ptrFormat = *(const uint16_t *)(segStarts + 6);
            uint64_t segOff = *(const uint64_t *)(segStarts + 8);
            uint16_t pageCount = *(const uint16_t *)(segStarts + 20);
            // 指针格式：1/7 是 arm64e（PAC 签名指针，改写会坏）；只接受 2/6（64 位无 PAC）。
            if (ptrFormat != 2 && ptrFormat != 6) {
                SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：指针格式 %u 不支持（须 DYLD_CHAINED_PTR_64/64_OFFSET）",
                                ptrFormat] UTF8String]);
                continue;
            }
            if (pageSize == 0) {
                continue;
            }
            for (uint16_t pi = 0; pi < pageCount; pi++) {
                if ((size_t)(segStarts - fixups) + 22 + pi * 2 + 2 > chainedDatasize) {
                    break;
                }
                uint16_t pageStart = *(const uint16_t *)(segStarts + 22 + pi * 2);
                if (pageStart == 0xFFFF) {
                    continue;
                }
                uint64_t pos = segOff + (uint64_t)pi * pageSize + pageStart;
                uint32_t steps = 0;
                while (steps++ < SB_MAX_CHAIN_STEPS) {
                    // 从文件读原始链项（内存里的槽已被 dyld 写成解析地址，不能走链）。
                    uint64_t raw = 0;
                    fseek(file, (long)(baseOffset + pos), SEEK_SET);
                    if (fread(&raw, sizeof(raw), 1, file) != 1) {
                        break;
                    }
                    BOOL isBind = (raw >> 63) & 1;
                    uint32_t next = (uint32_t)((raw >> 52) & 0x7FF);
                    if (isBind) {
                        uint32_t ordinal = (uint32_t)(raw & 0xFFFF);
                        if ((int32_t)ordinal == targetOrdinal) {
                            uintptr_t slotAddr =
                                SBFileOffsetToRuntimeAddress(layout, pos);
                            if (slotAddr != 0 &&
                                SBRewriteSlot(slotAddr, replacement)) {
                                rewrote++;
                                SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：%@ 槽已改写（文件偏移 0x%llx，运行时地址 0x%lx）",
                                                [NSString stringWithUTF8String:symbolName],
                                                (unsigned long long)pos,
                                                (unsigned long)slotAddr] UTF8String]);
                            }
                        }
                    }
                    if (next == 0) {
                        break;
                    }
                    pos += (uint64_t)next * 8;
                }
            }
        }
    } while (0);
    free(fixups);
    fclose(file);
    return rewrote;
}

#pragma mark - 传统懒绑定路（读内存间接符号表）

/// 传统路：按间接符号表按名找 __la/__nl_symbol_ptr 槽并改写。返回改写的槽数。
/// 间接符号表与字符串表在 __LINKEDIT，dyld 不改写它们，可直接读内存。
static uint32_t SBRebindClassic(SBImageLayout *layout,
                                const char *symbolName,
                                void *replacement) {
    if (layout->symoff == 0 || layout->stroff == 0 || layout->strsize == 0 ||
        layout->indirectSymoff == 0 || layout->nindirectSyms == 0) {
        return 0;
    }
    const uint8_t *symtab = SBLinkeditPointer(layout, layout->symoff);
    const uint8_t *strtab = SBLinkeditPointer(layout, layout->stroff);
    const uint8_t *indirect = SBLinkeditPointer(layout, layout->indirectSymoff);
    if (!symtab || !strtab || !indirect) {
        return 0;
    }
    const struct load_command *lc =
        (const struct load_command *)((const uint8_t *)layout->header +
                                      sizeof(struct mach_header_64));
    uint32_t rewrote = 0;
    for (uint32_t i = 0; i < layout->header->ncmds; i++) {
        uint32_t baseCmd = lc->cmd & 0x7FFFFFFF;
        if (baseCmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg =
                (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, "__DATA", 6) != 0 &&
                strncmp(seg->segname, "__DATA_CONST", 12) != 0 &&
                strncmp(seg->segname, "__AUTH_CONST", 12) != 0) {
                if (lc->cmdsize == 0) {
                    break;
                }
                lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
                continue;
            }
            const struct section_64 *sections =
                (const struct section_64 *)((const uint8_t *)seg +
                                            sizeof(struct segment_command_64));
            for (uint32_t j = 0; j < seg->nsects; j++) {
                uint32_t sectType = sections[j].flags & SECTION_TYPE;
                if (sectType != S_LAZY_SYMBOL_POINTERS &&
                    sectType != S_NON_LAZY_SYMBOL_POINTERS) {
                    continue;
                }
                uint32_t nslots = (uint32_t)(sections[j].size / sizeof(void *));
                uint32_t firstIndex = sections[j].reserved1;
                for (uint32_t k = 0; k < nslots; k++) {
                    uint32_t indirectIndex = firstIndex + k;
                    if (indirectIndex >= layout->nindirectSyms) {
                        break;
                    }
                    uint32_t symIndex =
                        *(const uint32_t *)(indirect + indirectIndex * 4);
                    if (symIndex >= layout->nsyms) {
                        continue;
                    }
                    const struct nlist_64 *sym =
                        (const struct nlist_64 *)(symtab + symIndex * sizeof(*sym));
                    uint32_t strx = sym->n_un.n_strx;
                    if (strx >= layout->strsize) {
                        continue;
                    }
                    const char *name = (const char *)(strtab + strx);
                    if (strcmp(name, symbolName) != 0) {
                        continue;
                    }
                    uintptr_t slotAddr = (uintptr_t)(sections[j].addr +
                                                     layout->slide + k * sizeof(void *));
                    if (SBRewriteSlot(slotAddr, replacement)) {
                        rewrote++;
                        SBDiagLogLine([[NSString stringWithFormat:@"传统重绑：%@ 槽已改写（%s+%u，运行时地址 0x%lx）",
                                        [NSString stringWithUTF8String:symbolName],
                                        sections[j].sectname, k,
                                        (unsigned long)slotAddr] UTF8String]);
                    }
                }
            }
        }
        if (lc->cmdsize == 0) {
            break;
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    return rewrote;
}

#pragma mark - 入口

BOOL SBRebindGuestSymbolForImage(const struct mach_header *header,
                                 NSString *execPath,
                                 const char *symbolName,
                                 void *replacement) {
    if (!header || !symbolName || !replacement) {
        return NO;
    }
    SBImageLayout layout;
    if (!SBParseImageLayout(header, &layout)) {
        SBDiagLogLine(@"重绑：镜像头非法（非 64 位 Mach-O）");
        return NO;
    }
    uint32_t rewrote = 0;
    if (layout.hasChainedFixups) {
        if (execPath.length == 0) {
            SBDiagLogLine(@"重绑：链式修正镜像须给可执行文件路径（链项只在磁盘文件里）");
            return NO;
        }
        rewrote = SBRebindChained(&layout, execPath, symbolName, replacement);
        if (rewrote == 0) {
            SBDiagLogLine([[NSString stringWithFormat:@"重绑：%@ 链式修正路未找到槽",
                            [NSString stringWithUTF8String:symbolName]] UTF8String]);
        }
    } else {
        rewrote = SBRebindClassic(&layout, symbolName, replacement);
        if (rewrote == 0) {
            SBDiagLogLine([[NSString stringWithFormat:@"重绑：%@ 传统懒绑定路未找到槽",
                            [NSString stringWithUTF8String:symbolName]] UTF8String]);
        }
    }
    return rewrote > 0;
}
