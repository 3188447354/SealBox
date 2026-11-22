// SBChainedFixupRebind.m — 链式修正感知的 GOT 重绑（0.2.28）。
//
// 实证布局（原型 0228，宿主二进制 Xcode 26.2 产物，DYLD_CHAINED_PTR_64_OFFSET）：
//   链项 8 字节：bit63 = bind 标志（1=bind，0=rebase）；bits 52-62 = next
//     （11 位，单位 8 字节）；bind 时 bits 0-15 = import 序号、bits 16-23 = addend；
//     rebase 时 bits 0-51 = 目标偏移。
//   import 项：DYLD_CHAINED_IMPORT 为 4 字节，ADDEND/ADDEND64 为 8 字节；
//     byte0 = lib 序号，bits 8-31（24 位）= 符号池内字节偏移 × 2。
//     0.2.29 根因修（Husk 3.4 实测）：0.2.28 这里写的是
//     ((v >> 8) & 0xFFFF) / 2——只取了 bits 8-23，把 24 位符号偏移的高
//     字节截掉了。符号池字节偏移 ≥32768 的符号（Husk 的 App.main 在
//     54364，池共 121168 字节）算出来是池内另一处碎片，名永远对不上，
//     targetOrdinal 恒 -1，报“链式修正路未找到槽”。宿主二进制池小
//     （App.main 偏移 <32768），掩码是空操作，原型验证才没抓到。
//     修正后 (v >> 8) / 2：Husk 3260 个 import 全解出干净名，
//     App.main 序号 1820，链里恰好 1 个 bind 槽（__DATA_CONST 0x64ced0）；
//     宿主二进制 App.main 序号仍是 711，不变，无回归。
//
// 0.2.31 根因修（Husk 2.0 真机，SealBox-2026-11-21-010321.ips）：
//   0.2.30 日志说槽已改写（import 序号 1972、文件偏移 0x4fe260），但钩子
//   根本没触发，客 App.main 照跑、第二遍 runApp 断言崩。离线核实（Husk 2.0
//   官方 IPA，指纹与已装一致：imports 2911、池 104216、入口 0x18519c）：
//   入口调 stub 0x3a4c1c，stub 读 __got 槽 vmaddr 0x1004fe260（= 文件偏移
//   0x4fe260），正是重绑找到的那个槽——槽没找错，错的是换算：
//   文件偏移→运行时地址算出来 0x125cba260（设备日志），比 stub 真正读的
//   0x125cb6260 高一页（0x4000），写到了别的槽里。错在手算 slide（header -
//   首段 vmaddr）：首段是 __PAGEZERO（vmaddr 0）时算出来的是 header 本身
//   （镜像基址），根本不是 slide——按文件段表忠实模拟，旧换算会得到
//   0x225CB6260（高 0x100000000），与设备日志的 0x125CBA260 仍对不上，
//   说明内存里首段记录与文件并不一致、具体哪一项差了一页在本机上看不到。
//   结论：手算 slide 不可信。修法：slide 改用 dyld API _dyld_get_image_vmaddr_slide（客入口 runtimeAddressForImageAtPath
//   同款用法，早就是对的）；写前用 dlsym 取期望地址比对槽原值，对不上
//   不写、走护栏；写后回读，不一致即失败；同一符号的全部 import 序号
//   都收，不只第一个。任何一步失败都干净失败、不跳 main。
//
// 关键：链式修正的原始链项只在磁盘文件里——dlopen 后 dyld 已把 __got 槽
// 写成解析后的函数地址，编码（bind/next/序号）被覆盖，内存里走不了链。
// 所以链式路读磁盘文件找槽的文件偏移，再按段 vmaddr+slide 换算成运行时地址
// 改写。传统路不依赖槽位当前值（按间接符号表按名找槽号），可直接读内存。
// 安全：只在 import 名与目标符号逐字相等时改写；布局对不上（名解不出来）
// 时找不到槽，返回 NO 走护栏，不会误改别的槽。
#import "SBChainedFixupRebind.h"

#import <dlfcn.h>
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

#define SB_MAX_SEGMENTS 32 // 0.2.29：16→32，超大镜像兜底（Husk 5 段，用不上；超限记日志）
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

/// 取镜像的 vmaddr slide：优先用 dyld API（_dyld_get_image_vmaddr_slide）。
// 0.2.31 根因：手算 header - firstSegVmaddr 是错的——首段是 __PAGEZERO
//（vmaddr 0）时算出来的是 header 本身（镜像基址），根本不是 slide；按文件
// 段表忠实模拟，旧换算会得到 0x225CB6260（比真槽高 0x100000000），与设备
// 日志的 0x125CBA260（比真槽高一页）仍对不上，说明内存里首段记录与文件
// 并不一致、具体哪一项差了一页在本机上看不到。结论：手算 slide 不可信。
// 客入口 runtimeAddressForImageAtPath 早就用 dyld API（正确），重绑路
// 现在跟它一致。找不到镜像序号时回退到 header - __TEXT 段 vmaddr
//（fileoff==0 的段即镜像基址段），并记日志。
static uintptr_t SBSlideForHeader(const struct mach_header *header,
                                  SBImageLayout *layout) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (_dyld_get_image_header(i) == header) {
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            SBDiagLogLine([[NSString stringWithFormat:@"重绑：slide 取自 dyld API（镜像序号 %u）= 0x%lx",
                            i, (unsigned long)slide] UTF8String]);
            return (uintptr_t)slide;
        }
    }
    for (uint32_t i = 0; i < layout->segmentCount; i++) {
        if (layout->segments[i].fileoff == 0 && layout->segments[i].filesize > 0) {
            uintptr_t slide = (uintptr_t)header - (uintptr_t)layout->segments[i].vmaddr;
            SBDiagLogLine([[NSString stringWithFormat:@"重绑：dyld 里找不到镜像头，slide 回退到 header-%@ = 0x%lx",
                            [NSString stringWithUTF8String:layout->segments[i].segname],
                            (unsigned long)slide] UTF8String]);
            return slide;
        }
    }
    // 兜底：首段 vmaddr（段表非空时才走到这里，SBParseImageLayout 已保证）。
    uintptr_t slide = (uintptr_t)header - (uintptr_t)layout->segments[0].vmaddr;
    SBDiagLogLine([[NSString stringWithFormat:@"重绑：dyld 里找不到镜像头且无 fileoff==0 的段，slide 回退到 header-首段 = 0x%lx",
                    (unsigned long)slide] UTF8String]);
    return slide;
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
    BOOL haveFirstSeg = NO;
    BOOL segmentOverflowLogged = NO; // 0.2.29：段数超上限时记一行（静默丢段会误判）
    for (uint32_t i = 0; i < header64->ncmds; i++) {
        uint32_t baseCmd = lc->cmd & 0x7FFFFFFF; // 去 LC_REQ_DYLD 位
        if (baseCmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg =
                (const struct segment_command_64 *)lc;
            if (!haveFirstSeg) {
                haveFirstSeg = YES;
            }
            if (layout->segmentCount < SB_MAX_SEGMENTS) {
                SBSegmentInfo *info = &layout->segments[layout->segmentCount++];
                memcpy(info->segname, seg->segname, 16);
                info->segname[16] = '\0';
                info->vmaddr = seg->vmaddr;
                info->fileoff = seg->fileoff;
                info->filesize = seg->filesize;
            } else if (!segmentOverflowLogged) {
                segmentOverflowLogged = YES;
                SBDiagLogLine([[NSString stringWithFormat:@"重绑：镜像段数超过上限 %u（%s 及之后段被丢弃，文件偏移换算可能不准）",
                                SB_MAX_SEGMENTS, seg->segname] UTF8String]);
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
    // 0.2.31：slide 不再手算（header - 首段 vmaddr 偏一页，见 SBSlideForHeader）。
    layout->slide = SBSlideForHeader(header, layout);
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
    // 0.2.31：写后回读——写保护/TPRO 没生效时写指令可能静默丢掉，
    // 回读对不上即失败（调用方走护栏，不跳 main）。
    if (*(void **)slotAddress != replacement) {
#if __arm64__
        if (needsTPRORevert) {
            os_thread_self_restrict_tpro_to_ro();
        }
#endif
        return NO;
    }
#if __arm64__
    if (needsTPRORevert) {
        os_thread_self_restrict_tpro_to_ro();
    }
#endif
    return YES;
}

/// 写槽前校验（只用于链式修正路）：槽里当前值应是目标符号的解析地址
///（dyld 在 dlopen 时已把 __got 槽绑好）。用 dlsym 取期望地址比对；
//对不上说明地址算错、或槽根本不是目标符号——不写，调用方走护栏。
//dlsym 解析不到时跳过校验（只记一行，不拦重绑）。
//0.2.32：槽里已是本进程钩子（replacement）即认作已装上、复用，不重写、
//不失败——同进程再点同一客（0.2.31 真机第二遍 Husk：槽值 0x104a703a4
//是钩子地址，≠ 期望原值 0x18c0c4964，旧校验判失败走护栏）。
//注意：传统懒绑定路不用它——懒槽未绑定时原值还是 dyld stub 地址，
//预校验会误判（见 SBRebindClassic）。
//symbolName 带前导 '_'（符号表形态），dlsym 要去 '_' 后的名字。
//返回：1=一致可写，0=不一致不可写，-1=无法校验（跳过），
//      2=槽里已是本进程钩子（复用，不重写）。
static int SBSlotPrecheck(uintptr_t slotAddress, const char *symbolName,
                          void *replacement) {
    if (slotAddress == 0 || !symbolName || symbolName[0] == '\0') {
        return 0;
    }
    const char *lookup = (symbolName[0] == '_') ? symbolName + 1 : symbolName;
    void *expected = dlsym(RTLD_DEFAULT, lookup);
    if (!expected) {
        SBDiagLogLine([[NSString stringWithFormat:@"重绑预校验：dlsym 解析不到 %@，跳过预校验",
                        [NSString stringWithUTF8String:symbolName]] UTF8String]);
        return -1;
    }
    void *current = *(void **)slotAddress;
    if (replacement && current == replacement) {
        SBDiagLogLine([[NSString stringWithFormat:@"重绑预校验：槽 0x%lx 已是本进程钩子 0x%lx（上次重绑留下的），复用，不重写",
                        (unsigned long)slotAddress, (unsigned long)current] UTF8String]);
        return 2;
    }
    if (current == expected) {
        SBDiagLogLine([[NSString stringWithFormat:@"重绑预校验：槽 0x%lx 原值 0x%lx 与期望一致",
                        (unsigned long)slotAddress, (unsigned long)current] UTF8String]);
        return 1;
    }
    SBDiagLogLine([[NSString stringWithFormat:@"重绑预校验失败：槽 0x%lx 原值 0x%lx ≠ 期望 0x%lx（地址算错或槽不是目标符号），不写",
                    (unsigned long)slotAddress, (unsigned long)current,
                    (unsigned long)expected] UTF8String]);
    return 0;
}

/// 按文件偏移找所在段名（日志用；找不到返回 "?"）。
static const char *SBSegmentNameForFileOffset(SBImageLayout *layout,
                                              uint64_t fileoff) {
    for (uint32_t i = 0; i < layout->segmentCount; i++) {
        SBSegmentInfo *seg = &layout->segments[i];
        if (fileoff >= seg->fileoff && fileoff < seg->fileoff + seg->filesize) {
            return seg->segname;
        }
    }
    return "?";
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

/// 0.2.44（B-5）：链式路失败的原因标志——置 1 当且仅当失败原因是“磁盘文件
/// 里没有 LC_DYLD_CHAINED_FIXUPS 数据”。入口清零；调度点读它决定是否退
/// 传统路再试。注意：它只救“头对、文件无链式数据”的情形，救不了“头错”
///（B 的 Guoguo 重进：头是别客的，传统路读的也是错头的间接符号表）。
static int g_chainedMissingData = 0;

/// 链式修正路：读磁盘文件，走链按 import 名找槽的文件偏移，换算成运行时地址
/// 改写。返回改写的槽数。layout 只用来做文件偏移→运行时地址换算与日志。
static uint32_t SBRebindChained(SBImageLayout *layout,
                                NSString *execPath,
                                const char *symbolName,
                                void *replacement) {
    g_chainedMissingData = 0;
    FILE *file = fopen([execPath UTF8String], "rb");
    if (!file) {
        SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：打不开可执行文件 %@",
                        execPath] UTF8String]);
        return 0;
    }
    uint64_t baseOffset = 0;
    if (!SBArm64SliceOffset(file, &baseOffset)) {
        SBDiagLogLine([@"链式重绑：取 arm64 切片偏移失败" UTF8String]);
        fclose(file);
        return 0;
    }
    uint32_t magic = 0;
    fseek(file, (long)baseOffset, SEEK_SET);
    if (fread(&magic, sizeof(magic), 1, file) != 1 || magic != 0xFEEDFACF) {
        SBDiagLogLine([@"链式重绑：切片头不是 64 位 Mach-O" UTF8String]);
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
        SBDiagLogLine([@"链式重绑：找不到 LC_DYLD_CHAINED_FIXUPS 数据" UTF8String]);
        g_chainedMissingData = 1;
        fclose(file);
        return 0;
    }
    // 把整段 fixup 数据读进内存（通常 < 100KB）。
    uint8_t *fixups = (uint8_t *)malloc(chainedDatasize);
    if (!fixups) {
        SBDiagLogLine([@"链式重绑：fixup 数据分配内存失败" UTF8String]);
        fclose(file);
        return 0;
    }
    fseek(file, (long)(baseOffset + chainedDataoff), SEEK_SET);
    if (fread(fixups, 1, chainedDatasize, file) != chainedDatasize) {
        SBDiagLogLine([@"链式重绑：读 fixup 数据失败" UTF8String]);
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
    uint32_t examinedBindSlots = 0; // 0.2.29：诊断——走链时见到的 bind 槽总数
    uint32_t matchedSlots = 0;      // 0.2.29：诊断——序号对上的槽数
    do {
        if (symbolsFormat != 0) {
            SBDiagLogLine([@"链式重绑：符号池是压缩格式，不支持" UTF8String]);
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
            SBDiagLogLine([@"链式重绑：fixup 头越界（import 表或符号池超出数据段）" UTF8String]);
            break;
        }
        const uint8_t *imports = fixups + importsOff;
        const uint8_t *pool = fixups + symbolsOff;
        size_t poolSize = chainedDatasize - symbolsOff;
        SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：%@ imports=%u（格式 %u，符号池格式 %u，池 %zu 字节）",
                        [NSString stringWithUTF8String:symbolName],
                        importsCount, importsFormat, symbolsFormat, poolSize] UTF8String]);
        // 找目标符号的全部 import 序号（名逐字相等才认；同一符号在表里
        // 出现多次时只取第一个会漏槽——0.2.31 起全收，最多 16 个）。
        int32_t targetOrdinals[16];
        uint32_t targetOrdinalCount = 0;
        BOOL ordinalOverflow = NO;
        for (uint32_t i = 0; i < importsCount; i++) {
            uint32_t v = *(const uint32_t *)(imports + i * importEntrySize);
            // 0.2.29：符号偏移是 bits 8-31 的 24 位值（= 字节偏移 × 2），
            // 不掩 0xFFFF——掩了会截掉高字节（Husk App.main 偏移 54364 被截成 21596）。
            uint32_t nameByteOff = (v >> 8) / 2;
            if (nameByteOff >= poolSize) {
                continue;
            }
            const char *name = (const char *)(pool + nameByteOff);
            size_t maxLen = poolSize - nameByteOff;
            if (strnlen(name, maxLen) >= maxLen) {
                continue;
            }
            if (strcmp(name, symbolName) == 0) {
                if (targetOrdinalCount < 16) {
                    targetOrdinals[targetOrdinalCount++] = (int32_t)i;
                } else {
                    ordinalOverflow = YES;
                }
            }
        }
        if (targetOrdinalCount == 0) {
            // 情形①：符号根本不在 import 表里（入口调的是镜像内特化/别处符号）。
            SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：%@ 不在 import 表里（共 %u 个 import）",
                            [NSString stringWithUTF8String:symbolName], importsCount] UTF8String]);
            break;
        }
        if (ordinalOverflow) {
            SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：%@ import 序号超过 16 个，只收前 16 个",
                            [NSString stringWithUTF8String:symbolName]] UTF8String]);
        }
        SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：%@ import 序号 %d（共 %u 个）",
                        [NSString stringWithUTF8String:symbolName],
                        targetOrdinals[0], targetOrdinalCount] UTF8String]);
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
            // 0.2.29：每段都记指针格式与页数（不论支不支持），下次真机日志能钉死
            // 是哪一段的格式问题；段名按段序取（starts 表与加载命令同序）。
            const char *segName = (si < layout->segmentCount)
                ? layout->segments[si].segname : "?";
            SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：段 %u（%s）指针格式 %u，%u 页",
                            si, segName, ptrFormat, pageCount] UTF8String]);
            // 指针格式：1/7 是 arm64e（PAC 签名指针，改写会坏）；只接受 2/6（64 位无 PAC）。
            if (ptrFormat != 2 && ptrFormat != 6) {
                SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：段 %u 指针格式 %u 不支持（须 DYLD_CHAINED_PTR_64/64_OFFSET），跳过",
                                si, ptrFormat] UTF8String]);
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
                        examinedBindSlots++;
                        uint32_t ordinal = (uint32_t)(raw & 0xFFFF);
                        BOOL ordinalMatches = NO;
                        for (uint32_t oi = 0; oi < targetOrdinalCount; oi++) {
                            if ((int32_t)ordinal == targetOrdinals[oi]) {
                                ordinalMatches = YES;
                                break;
                            }
                        }
                        if (ordinalMatches) {
                            matchedSlots++;
                            uintptr_t slotAddr =
                                SBFileOffsetToRuntimeAddress(layout, pos);
                            if (slotAddr == 0) {
                                // 情形③a：槽在文件里找到了，但换算不到运行时地址
                                //（段表对不上，如段数超上限被丢）。
                                SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：%@ 槽文件偏移 0x%llx 换算不到运行时地址",
                                                [NSString stringWithUTF8String:symbolName],
                                                (unsigned long long)pos] UTF8String]);
                            } else {
                                int precheck = SBSlotPrecheck(slotAddr, symbolName, replacement);
                                if (precheck == 0) {
                                    // 情形③c：槽原值与期望（dlsym 解析值）对不上——
                                    // 地址算错或槽不是目标符号，不写（0.2.30 的教训：
                                    // 写到错地址上钩子永不触发）。记为失败，走护栏。
                                    SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：%@ 槽预校验失败，不改写（文件偏移 0x%llx，运行时地址 0x%lx）",
                                                    [NSString stringWithUTF8String:symbolName],
                                                    (unsigned long long)pos,
                                                    (unsigned long)slotAddr] UTF8String]);
                                } else if (precheck == 2) {
                                    // 0.2.32：槽里已是本进程钩子（同进程再点同一客），
                                    // 复用，不重写；记为已装上，不走护栏。
                                    rewrote++;
                                    SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：%@ 槽已是本进程钩子（文件偏移 0x%llx，运行时地址 0x%lx），复用，不重写",
                                                    [NSString stringWithUTF8String:symbolName],
                                                    (unsigned long long)pos,
                                                    (unsigned long)slotAddr] UTF8String]);
                                } else if (SBRewriteSlot(slotAddr, replacement)) {
                                    rewrote++;
                                    SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：%@ 槽已改写（文件偏移 0x%llx，运行时地址 0x%lx，段 %s，slide=0x%lx，回读一致）",
                                                    [NSString stringWithUTF8String:symbolName],
                                                    (unsigned long long)pos,
                                                    (unsigned long)slotAddr,
                                                    SBSegmentNameForFileOffset(layout, pos),
                                                    (unsigned long)layout->slide] UTF8String]);
                                } else {
                                    // 情形③b：槽找到了，改写失败（vm_protect/TPRO）。
                                    SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：%@ 槽改写失败（文件偏移 0x%llx，运行时地址 0x%lx）",
                                                    [NSString stringWithUTF8String:symbolName],
                                                    (unsigned long long)pos,
                                                    (unsigned long)slotAddr] UTF8String]);
                                }
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
        if (rewrote == 0) {
            // 情形②：序号找到了，但链里没有引用它的 bind 槽（或改写全失败，
            // 含预校验失败——见上文）。
            SBDiagLogLine([[NSString stringWithFormat:@"链式重绑：%@ 序号 %d（共 %u 个），检查了 %u 个 bind 槽、%u 个匹配、改写 %u 个",
                            [NSString stringWithUTF8String:symbolName],
                            targetOrdinals[0], targetOrdinalCount,
                            examinedBindSlots, matchedSlots, rewrote] UTF8String]);
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
                    // 0.2.31：这里不用 SBSlotPrecheck——传统路的懒槽在未绑定时
                    // 原值还是 dyld stub 地址，不是目标函数地址，预校验会误判；
                    // 链式路的槽在 dlopen 时已由 dyld 绑好，预校验只在那里做。
                    // 写后回读在 SBRewriteSlot 里已做。
                    if (SBRewriteSlot(slotAddr, replacement)) {
                        rewrote++;
                        SBDiagLogLine([[NSString stringWithFormat:@"传统重绑：%@ 槽已改写（%s+%u，运行时地址 0x%lx，回读一致）",
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
        SBDiagLogLine([@"重绑：镜像头非法（非 64 位 Mach-O）" UTF8String]);
        return NO;
    }
    uint32_t rewrote = 0;
    if (layout.hasChainedFixups) {
        if (execPath.length == 0) {
            SBDiagLogLine([@"重绑：链式修正镜像须给可执行文件路径（链项只在磁盘文件里）" UTF8String]);
            return NO;
        }
        rewrote = SBRebindChained(&layout, execPath, symbolName, replacement);
        if (rewrote == 0 && g_chainedMissingData) {
            // 0.2.44（B-5）：链式路只报了“无数据”——头是对的、文件里就是
            // 没有链式数据（Guoguo 首开就是这情形：分类器报“链式修正=否”，
            // 但调度按内存头的 hasChainedFixups 走了链式路）。退传统路
            // 再试一次；传统路读的是内存头的间接符号表，头对才救得回来。
            SBDiagLogLine([@"重绑：链式路无数据，退传统路再试" UTF8String]);
            rewrote = SBRebindClassic(&layout, symbolName, replacement);
            if (rewrote == 0) {
                SBDiagLogLine([[NSString stringWithFormat:@"重绑：%@ 传统路亦未找到槽",
                                [NSString stringWithUTF8String:symbolName]] UTF8String]);
            }
        } else if (rewrote == 0) {
            // 具体原因（符号不在 import 表里 / 无引用它的槽 / 改写失败 /
            // 解析失败）已由 SBRebindChained 在上文逐条记下，这里只汇总。
            SBDiagLogLine([[NSString stringWithFormat:@"重绑：%@ 链式修正路未找到槽（见上文链式重绑诊断）",
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
