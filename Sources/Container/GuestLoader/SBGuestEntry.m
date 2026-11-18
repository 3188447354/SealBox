// SBGuestEntry.m — 客 App 入口：解析 Mach-O 读 LC_MAIN 的 entryoff、dlopen 客可执行、
// 取镜像内运行地址、32 位检测。只用公开头文件（mach-o/loader.h、fat.h、dyld.h）。
#import "SBGuestEntry.h"

#import <dlfcn.h>
#import <errno.h>
#import <libkern/OSByteOrder.h>
#import <mach-o/dyld.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <mach/machine.h>
#import <string.h>

#import "SBDiagLog.h"
#import "SBGuestLoader.h"

// LC_DYLD_CHAINED_FIXUPS 在公开头文件里有定义；这里只用它做段数不匹配的诊断提示。
#ifndef LC_DYLD_CHAINED_FIXUPS
#define LC_DYLD_CHAINED_FIXUPS 0x34
#endif

static NSError *SBEntryError(NSString *message) {
    return SBGuestLoaderErrorMake(SBGuestLoaderErrorEntryPointNotFound,
                                  @"加载客 App",
                                  message,
                                  @"请重新导入该应用");
}

#pragma mark - Mach-O 解析

/// 取 Mach-O 里 arm64/arm64e 切片的位置与 cputype。
/// fat 包挑 arm64e 优先，其次 arm64；薄包直接取自身；32 位薄包也返回其 cputype（供 32 位检测）。
static BOOL SBMachOSlice(NSData *data,
                         uint64_t *sliceOffsetOut,
                         uint64_t *sliceSizeOut,
                         uint32_t *cputypeOut) {
    if (data.length < sizeof(uint32_t)) {
        return NO;
    }
    uint32_t magic = 0;
    [data getBytes:&magic length:sizeof(magic)];
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        if (data.length < sizeof(struct fat_header)) {
            return NO;
        }
        struct fat_header fatHeader;
        [data getBytes:&fatHeader length:sizeof(fatHeader)];
        // 在小端机上读 FAT 文件，magic 是 FAT_CIGAM，字段是大端序，需要换字节；
        // 读到 FAT_MAGIC 说明文件本身是小端序，字段直接读。
        BOOL needsSwap = (magic == FAT_CIGAM);
        uint32_t archCount = needsSwap
            ? OSSwapBigToHostInt32(fatHeader.nfat_arch)
            : fatHeader.nfat_arch;
        if (archCount == 0 || archCount > 64) {
            return NO;
        }
        size_t needed = sizeof(struct fat_header) + (size_t)archCount * sizeof(struct fat_arch);
        if (data.length < needed) {
            return NO;
        }
        uint64_t arm64Offset = 0, arm64Size = 0;
        uint32_t arm64Cputype = 0;
        BOOL foundARM64 = NO;
        uint64_t firstOffset = 0, firstSize = 0;
        uint32_t firstCputype = 0;
        for (uint32_t i = 0; i < archCount; i++) {
            struct fat_arch arch;
            [data getBytes:&arch
                    range:NSMakeRange(sizeof(struct fat_header) + (size_t)i * sizeof(struct fat_arch),
                                      sizeof(arch))];
            uint32_t cputype = needsSwap ? OSSwapBigToHostInt32(arch.cputype) : arch.cputype;
            uint32_t cpusubtype = needsSwap ? OSSwapBigToHostInt32(arch.cpusubtype) : arch.cpusubtype;
            uint32_t offset = needsSwap ? OSSwapBigToHostInt32(arch.offset) : arch.offset;
            uint32_t size = needsSwap ? OSSwapBigToHostInt32(arch.size) : arch.size;
            if (i == 0) {
                firstOffset = offset;
                firstSize = size;
                firstCputype = cputype;
            }
            if (cputype != CPU_TYPE_ARM64) {
                continue;
            }
            if (cpusubtype == CPU_SUBTYPE_ARM64E) {
                // arm64e 最优先，直接取。
                if (sliceOffsetOut) *sliceOffsetOut = offset;
                if (sliceSizeOut) *sliceSizeOut = size;
                if (cputypeOut) *cputypeOut = cputype;
                return YES;
            }
            if (!foundARM64) {
                foundARM64 = YES;
                arm64Offset = offset;
                arm64Size = size;
                arm64Cputype = cputype;
            }
        }
        if (foundARM64) {
            if (sliceOffsetOut) *sliceOffsetOut = arm64Offset;
            if (sliceSizeOut) *sliceSizeOut = arm64Size;
            if (cputypeOut) *cputypeOut = arm64Cputype;
            return YES;
        }
        // 没有 arm64 切片：返回第一个切片（供调用方报“不支持的架构”）。
        if (sliceOffsetOut) *sliceOffsetOut = firstOffset;
        if (sliceSizeOut) *sliceSizeOut = firstSize;
        if (cputypeOut) *cputypeOut = firstCputype;
        return YES;
    }
    // 薄包：在小端机上，正常的 64/32 位 Mach-O 读出来是 MH_CIGAM_64 / MH_CIGAM，
    // 字段是小端序，直接读；读到 MH_MAGIC_64 / MH_MAGIC 说明文件字节序反了，拒绝。
    if (magic == MH_CIGAM_64 || magic == MH_CIGAM) {
        if (sliceOffsetOut) *sliceOffsetOut = 0;
        if (sliceSizeOut) *sliceSizeOut = (uint64_t)data.length;
        if (cputypeOut) {
            struct mach_header header;
            [data getBytes:&header length:sizeof(header)];
            *cputypeOut = header.cputype;
        }
        return YES;
    }
    return NO;
}

/// 在切片内按 load command 逐个找；回调拿到 cmd 与命令体在切片内的偏移。
/// bounds-checked：任何越界都停下返回 NO。
static BOOL SBEnumerateLoadCommands(NSData *data,
                                    uint64_t sliceOffset,
                                    uint64_t sliceSize,
                                    BOOL (^handler)(uint32_t cmd, uint64_t commandOffset, uint32_t commandSize)) {
    if (sliceSize < sizeof(struct mach_header_64)) {
        return NO;
    }
    struct mach_header_64 header;
    [data getBytes:&header range:NSMakeRange((NSUInteger)sliceOffset, sizeof(header))];
    if (header.magic != MH_MAGIC_64 && header.magic != MH_CIGAM_64) {
        return NO;
    }
    uint64_t cursor = sliceOffset + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header.ncmds; i++) {
        if (cursor + sizeof(struct load_command) > sliceOffset + sliceSize) {
            return NO;
        }
        struct load_command command;
        [data getBytes:&command range:NSMakeRange((NSUInteger)cursor, sizeof(command))];
        if (command.cmdsize < sizeof(struct load_command)) {
            return NO;
        }
        if (cursor + command.cmdsize > sliceOffset + sliceSize) {
            return NO;
        }
        if (!handler(command.cmd, cursor, command.cmdsize)) {
            return YES; // 回调要求停下（已找到），不算错
        }
        cursor += command.cmdsize;
    }
    return YES;
}

#pragma mark - 对外接口

BOOL getAppEntryPoint(NSString *machOPath, uint64_t *entryoffOut, NSError **error) {
    if (entryoffOut) {
        *entryoffOut = 0;
    }
    NSData *data = [NSData dataWithContentsOfFile:machOPath];
    if (!data) {
        // 0.2.10 报错日志：之前只返错不记日志，读失败的原因（权限/不存在）
        // 全丢了；errno 在这里现取。
        int readErrno = errno;
        SBDiagLogLine([[NSString stringWithFormat:@"客入口：读可执行文件失败：%@ errno=%d", machOPath, readErrno] UTF8String]);
        if (error) {
            *error = SBEntryError(@"找不到客 App 入口：读不到可执行文件");
        }
        return NO;
    }
    uint64_t sliceOffset = 0, sliceSize = 0;
    uint32_t cputype = 0;
    if (!SBMachOSlice(data, &sliceOffset, &sliceSize, &cputype)) {
        SBDiagLogLine([[NSString stringWithFormat:@"客入口：不是有效的 Mach-O 文件：%@ 文件大小=%lu", machOPath, (unsigned long)data.length] UTF8String]);
        if (error) {
            *error = SBEntryError(@"找不到客 App 入口：不是有效的 Mach-O 文件");
        }
        return NO;
    }
    if (cputype != CPU_TYPE_ARM64) {
        SBDiagLogLine([[NSString stringWithFormat:@"客入口：不是 64 位应用：%@ cputype=0x%x", machOPath, cputype] UTF8String]);
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorUnsupportedBinary,
                                            @"加载客 App",
                                            @"该应用不是 64 位应用，无法加载",
                                            @"请换用 64 位版本");
        }
        return NO;
    }
    __block uint64_t entryoff = 0;
    __block BOOL found = NO;
    BOOL enumerated = SBEnumerateLoadCommands(data, sliceOffset, sliceSize,
        ^BOOL(uint32_t cmd, uint64_t commandOffset, uint32_t commandSize) {
            if (cmd != LC_MAIN) {
                return YES; // 继续找
            }
            if (commandSize < sizeof(struct entry_point_command)) {
                return NO;
            }
            struct entry_point_command entryPoint;
            [data getBytes:&entryPoint
                    range:NSMakeRange((NSUInteger)commandOffset, sizeof(entryPoint))];
            entryoff = entryPoint.entryoff;
            found = YES;
            return NO; // 停下
        });
    if (!enumerated || !found) {
        SBDiagLogLine([[NSString stringWithFormat:@"客入口：可执行文件里没有 LC_MAIN：%@", machOPath] UTF8String]);
        if (error) {
            *error = SBEntryError(@"找不到客 App 入口：可执行文件里没有 LC_MAIN");
        }
        return NO;
    }
    if (entryoffOut) {
        *entryoffOut = entryoff;
    }
    return YES;
}

void *dlopenGuest(NSString *path, NSError **error) {
    void *handle = dlopen([path UTF8String], RTLD_LAZY | RTLD_GLOBAL | RTLD_FIRST);
    if (handle) {
        SBDiagLogLine([[NSString stringWithFormat:@"客加载：dlopen 客可执行成功：%@", path] UTF8String]);
        return handle;
    }
    // dlopen 失败：errno 要在 dlerror() 之前现取（后面的 NSString
    // 分配可能改掉它）；dlerror 原文照原样记进日志。
    int dlopenErrno = errno;
    const char *dlerrorString = dlerror();
    NSString *detail = dlerrorString ? [NSString stringWithUTF8String:dlerrorString] : @"未知错误";
    SBDiagLogLine([[NSString stringWithFormat:@"客加载：dlopen 客可执行失败：[code=%ld] %@%@ dyld 原文：%@", (long)SBGuestLoaderErrorGuestLoadFailed, path, dlopenErrno != 0 ? [NSString stringWithFormat:@" errno=%d", dlopenErrno] : @"", detail] UTF8String]);
    NSInteger majorVersion = [[NSProcessInfo processInfo] operatingSystemVersion].majorVersion;
    NSString *message = nil;
    NSString *recovery = @"请重试，或重新导入该应用";
    if (majorVersion >= 27 &&
        ([detail rangeOfString:@"segment" options:NSCaseInsensitiveSearch].location != NSNotFound ||
         [detail rangeOfString:@"fixup" options:NSCaseInsensitiveSearch].location != NSNotFound ||
         [detail rangeOfString:@"chained" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        // iOS 27 段数不匹配：v1 没有 dyld 内部绕过（需要私有符号，见 MODULE_NOTES），
        // 报错里追加 dyld 原文（0.2.5 边界：报 dyld 原文，不替用户翻译掉）。
        message = [NSString stringWithFormat:
                   @"客 App 加载失败：该应用的段数与当前系统不匹配（iOS 27），暂不支持\ndyld 原文：%@",
                   detail];
        recovery = @"请换用适配当前系统的版本，或等后续更新";
    } else {
        message = [NSString stringWithFormat:@"客 App 加载失败：%@", detail];
    }
    if (error) {
        *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorGuestLoadFailed,
                                        @"加载客 App",
                                        message,
                                        recovery);
    }
    return NULL;
}

BOOL is32BitMachOAtPath(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return NO;
    }
    uint64_t sliceOffset = 0, sliceSize = 0;
    uint32_t cputype = 0;
    if (!SBMachOSlice(data, &sliceOffset, &sliceSize, &cputype)) {
        return NO;
    }
    return cputype != CPU_TYPE_ARM64;
}

BOOL runtimeAddressForImageAtPath(NSString *imagePath,
                                  uint64_t fileOffset,
                                  uintptr_t *addressOut,
                                  NSError **error) {
    if (addressOut) {
        *addressOut = 0;
    }
    NSString *wantedName = [imagePath lastPathComponent];
    // 两遍匹配：先精确全路径，再退到同名——同名不同路径的镜像（如
    // 同名 framework）先被扫到会算错入口。
    for (int pass = 0; pass < 2; pass++) {
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            const char *imageName = _dyld_get_image_name(i);
            if (!imageName) {
                continue;
            }
            NSString *loadedPath = [NSString stringWithUTF8String:imageName];
            BOOL matches = (pass == 0)
                ? [loadedPath isEqualToString:imagePath]
                : [[loadedPath lastPathComponent] isEqualToString:wantedName];
            if (!matches) {
                continue;
            }
            const struct mach_header *header = _dyld_get_image_header(i);
            if (!header) {
                continue;
            }
            // 0.2.4 根因修：_dyld_get_image_header 返回的已是滑移后的
            // 实际加载地址，LC_MAIN 的 entryoff 是从文件头的偏移，
            // 入口 = header + entryoff。旧代码又加了一次 slide
            // （header + slide + entryoff），入口偏了整整一个 slide，
            // 跳过去必崩（EXC_BAD_ACCESS）——点客应用图标必闪退的根因，
            // 0.2.0 起就有，真机从未验过。slide 只对从文件里读出的
            // preferred vmaddr 才要加，这里不加。
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            uintptr_t entryAddress = (uintptr_t)header + (uintptr_t)fileOffset;
            SBDiagLogLine([[NSString stringWithFormat:
                @"客入口：镜像=%@ header=0x%lx slide=0x%lx entryoff=0x%llx 入口=0x%lx",
                loadedPath, (unsigned long)header, (unsigned long)slide,
                (unsigned long long)fileOffset, (unsigned long)entryAddress] UTF8String]);
            if (addressOut) {
                *addressOut = entryAddress;
            }
            return YES;
        }
    }
    if (error) {
        *error = SBEntryError(@"找不到客 App 入口：客 App 镜像未加载");
    }
    // 0.2.10 报错日志：之前只返错不记日志；记下要找的镜像、已加载
    // 镜像数与 entryoff，定位“dlopen 成功了但镜像不在列表里”。
    SBDiagLogLine([[NSString stringWithFormat:@"客入口：镜像未加载：%@ 已加载镜像数=%u entryoff=0x%llx", imagePath, _dyld_image_count(), (unsigned long long)fileOffset] UTF8String]);
    return NO;
}
