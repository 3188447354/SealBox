// SBGuestUIClassifier.m — 客 App 的 UI 类型分型（0.2.28）。
#import "SBGuestUIClassifier.h"

#import <mach-o/loader.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#import "SBDiagLog.h"

// SwiftUI App.main 的真实符号：main 不是 App 协议的 requirement，而是协议
// 扩展里的方法（PAAE = protocol extension），所以是 PAAE 版不是 P4 版。
// （原型 0228 第 2/3 组实证：宿主二进制未定义符号里确有此串。）
static const char * const SBAppMainSymbol = "_$s7SwiftUI3AppPAAE4mainyyFZ";
static const char * const SBUIApplicationMainSymbol = "_UIApplicationMain";
// Swift 覆盖层 UIApplicationMain（0.2.30）：Swift @main / @UIApplicationMain
// 生成的 main 调 UIKit.UIApplicationMain，不是 C UIApplicationMain——
// 原型 0230：OmoFun Runner 未定义符号里有它（C 符号没有），链式 import 序号 41。
static const char * const SBSwiftUIApplicationMainSymbol =
    "_$s5UIKit17UIApplicationMainys5Int32VAD_SpySpys4Int8VGGSgSSSgAJtF";

SBGuestUIType SBGuestUITypeForGuestExecutable(NSString *execPath) {
    if (execPath.length == 0) {
        return SBGuestUITypeUnknown;
    }
    FILE *file = fopen([execPath UTF8String], "rb");
    if (!file) {
        return SBGuestUITypeUnknown;
    }
    uint32_t magic = 0;
    if (fread(&magic, sizeof(magic), 1, file) != 1) {
        fclose(file);
        return SBGuestUITypeUnknown;
    }
    // fat 二进制：取 arm64 切片（0.2.27 同款做法）。
    uint64_t baseOffset = 0;
    if (magic == 0xCAFEBABE || magic == 0xBEBAFECA) {
        uint32_t nfat = 0;
        BOOL swapped = (magic == 0xBEBAFECA);
        fseek(file, 4, SEEK_SET);
        if (fread(&nfat, sizeof(nfat), 1, file) != 1) {
            fclose(file);
            return SBGuestUITypeUnknown;
        }
        if (swapped) {
            nfat = __builtin_bswap32(nfat);
        }
        BOOL found = NO;
        for (uint32_t i = 0; i < nfat; i++) {
            uint32_t cputype = 0, offset = 0;
            fseek(file, 8 + i * 20, SEEK_SET);
            if (fread(&cputype, sizeof(cputype), 1, file) != 1) {
                break;
            }
            if (swapped) {
                cputype = __builtin_bswap32(cputype);
            }
            fseek(file, 8 + i * 20 + 8, SEEK_SET);
            if (fread(&offset, sizeof(offset), 1, file) != 1) {
                break;
            }
            if (swapped) {
                offset = __builtin_bswap32(offset);
            }
            if (cputype == 0x0100000C) { // CPU_TYPE_ARM64
                baseOffset = offset;
                found = YES;
                break;
            }
        }
        if (!found) {
            fclose(file);
            return SBGuestUITypeUnknown;
        }
        fseek(file, (long)baseOffset, SEEK_SET);
        if (fread(&magic, sizeof(magic), 1, file) != 1) {
            fclose(file);
            return SBGuestUITypeUnknown;
        }
    }
    BOOL is64 = (magic == 0xFEEDFACF);
    if (!is64 && magic != 0xFEEDFACE) {
        fclose(file);
        return SBGuestUITypeUnknown;
    }
    uint32_t ncmds = 0;
    fseek(file, (long)(baseOffset + 16), SEEK_SET);
    if (fread(&ncmds, sizeof(ncmds), 1, file) != 1) {
        fclose(file);
        return SBGuestUITypeUnknown;
    }
    uint64_t cursor = baseOffset + (is64 ? 32 : 28);
    uint32_t symoff = 0, nsyms = 0, stroff = 0, strsize = 0;
    uint32_t iundefsym = 0, nundefsym = 0;
    BOOL hasDyldInfo = NO;
    BOOL hasChainedFixups = NO;
    BOOL linksFlutter = NO;
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = 0, cmdsize = 0;
        fseek(file, (long)cursor, SEEK_SET);
        if (fread(&cmd, sizeof(cmd), 1, file) != 1 ||
            fread(&cmdsize, sizeof(cmdsize), 1, file) != 1) {
            fclose(file);
            return SBGuestUITypeUnknown;
        }
        uint32_t baseCmd = cmd & 0x7FFFFFFF; // 去 LC_REQ_DYLD 位
        if (baseCmd == 0x2) { // LC_SYMTAB
            fseek(file, (long)(cursor + 8), SEEK_SET);
            if (fread(&symoff, sizeof(symoff), 1, file) != 1 ||
                fread(&nsyms, sizeof(nsyms), 1, file) != 1 ||
                fread(&stroff, sizeof(stroff), 1, file) != 1 ||
                fread(&strsize, sizeof(strsize), 1, file) != 1) {
                fclose(file);
                return SBGuestUITypeUnknown;
            }
        } else if (baseCmd == 0xB) { // LC_DYSYMTAB
            uint32_t fields[6] = {0};
            fseek(file, (long)(cursor + 8), SEEK_SET);
            if (fread(fields, sizeof(uint32_t), 6, file) != 6) {
                fclose(file);
                return SBGuestUITypeUnknown;
            }
            iundefsym = fields[4];
            nundefsym = fields[5];
        } else if (baseCmd == 0x22) { // LC_DYLD_INFO_ONLY
            hasDyldInfo = YES;
        } else if (baseCmd == 0x34) { // LC_DYLD_CHAINED_FIXUPS
            hasChainedFixups = YES;
        } else if (baseCmd == 0xC || baseCmd == 0x18 || baseCmd == 0x1F ||
                   baseCmd == 0x20 || baseCmd == 0x23) {
            // LC_LOAD_DYLIB / WEAK / REEXPORT / LAZY / UPWARD：读安装名。
            uint32_t nameoff = 0;
            fseek(file, (long)(cursor + 8), SEEK_SET);
            if (fread(&nameoff, sizeof(nameoff), 1, file) != 1) {
                fclose(file);
                return SBGuestUITypeUnknown;
            }
            fseek(file, (long)(cursor + nameoff), SEEK_SET);
            char name[256] = {0};
            size_t got = fread(name, 1, sizeof(name) - 1, file);
            if (got > 0 && strstr(name, "Flutter.framework") != NULL) {
                linksFlutter = YES;
            }
        }
        if (cmdsize == 0) {
            break;
        }
        cursor += cmdsize;
    }
    (void)hasDyldInfo;
    // 未定义符号里找三个目标符号（0.2.30：C 符号之外再加 Swift 覆盖层符号——
    // Swift-main 客只有覆盖层符号，没有 C 符号；只查 C 符号会把 Flutter/
    // Swift UIKit 客漏成未知，拦截门也跟着瞎）。
    BOOL hasUIApplicationMain = NO;
    BOOL hasSwiftUIApplicationMain = NO;
    BOOL hasAppMain = NO;
    BOOL hasSymtab = (symoff != 0 && stroff != 0 && strsize != 0 && nundefsym != 0);
    if (hasSymtab) {
        size_t entrySize = is64 ? 16 : 12;
        for (uint32_t i = iundefsym; i < iundefsym + nundefsym && i < nsyms; i++) {
            uint32_t strx = 0;
            fseek(file, (long)(baseOffset + symoff + i * entrySize), SEEK_SET);
            if (fread(&strx, sizeof(strx), 1, file) != 1) {
                break;
            }
            if (strx >= strsize) {
                continue;
            }
            fseek(file, (long)(baseOffset + stroff + strx), SEEK_SET);
            char name[128] = {0};
            size_t got = fread(name, 1, sizeof(name) - 1, file);
            if (got == 0) {
                continue;
            }
            if (strcmp(name, SBUIApplicationMainSymbol) == 0) {
                hasUIApplicationMain = YES;
            } else if (strcmp(name, SBSwiftUIApplicationMainSymbol) == 0) {
                hasSwiftUIApplicationMain = YES;
            } else if (strcmp(name, SBAppMainSymbol) == 0) {
                hasAppMain = YES;
            }
            if (hasUIApplicationMain && hasSwiftUIApplicationMain && hasAppMain) {
                break;
            }
        }
    }
    fclose(file);
    SBGuestUIType type = SBGuestUITypeUnknown;
    if (linksFlutter) {
        // Flutter 优先：Runner 调的是 Swift 覆盖层 UIApplicationMain，
        // 单看 C 符号会漏判（0.2.29 的“_UIApplicationMain=否”即此盲区）。
        type = SBGuestUITypeFlutter;
    } else if (hasUIApplicationMain || hasSwiftUIApplicationMain) {
        type = SBGuestUITypeUIKit;
    } else if (hasAppMain) {
        type = SBGuestUITypeSwiftUI;
    }
    SBDiagLogLine([[NSString stringWithFormat:@"客分型：%@ → %@（链 Flutter=%@，C _UIApplicationMain=%@，Swift UIApplicationMain=%@，App.main=%@，链式修正=%@，符号表=%@）",
                    execPath.lastPathComponent, SBGuestUITypeToString(type),
                    linksFlutter ? @"是" : @"否",
                    hasUIApplicationMain ? @"是" : @"否",
                    hasSwiftUIApplicationMain ? @"是" : @"否",
                    hasAppMain ? @"是" : @"否",
                    hasChainedFixups ? @"是" : @"否",
                    hasSymtab ? @"有" : @"无（符号被剥，符号结果不可信）"] UTF8String]);
    return type;
}

NSString *SBGuestUITypeToString(SBGuestUIType type) {
    switch (type) {
        case SBGuestUITypeUIKit:
            return @"uikit";
        case SBGuestUITypeSwiftUI:
            return @"swiftui";
        case SBGuestUITypeFlutter:
            return @"flutter";
        case SBGuestUITypeUnknown:
        default:
            return @"unknown";
    }
}
