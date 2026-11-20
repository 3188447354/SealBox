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
    // 未定义符号里找两个目标符号。
    BOOL hasUIApplicationMain = NO;
    BOOL hasAppMain = NO;
    if (symoff != 0 && stroff != 0 && strsize != 0 && nundefsym != 0) {
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
            } else if (strcmp(name, SBAppMainSymbol) == 0) {
                hasAppMain = YES;
            }
            if (hasUIApplicationMain && hasAppMain) {
                break;
            }
        }
    }
    fclose(file);
    SBGuestUIType type = SBGuestUITypeUnknown;
    if (linksFlutter) {
        // Flutter 优先：Runner 也直接调 UIApplicationMain，单看符号会误判 UIKit。
        type = SBGuestUITypeFlutter;
    } else if (hasUIApplicationMain) {
        type = SBGuestUITypeUIKit;
    } else if (hasAppMain) {
        type = SBGuestUITypeSwiftUI;
    }
    SBDiagLogLine([[NSString stringWithFormat:@"客分型：%@ → %@（链 Flutter=%@，_UIApplicationMain=%@，App.main=%@，链式修正=%@）",
                    execPath.lastPathComponent, SBGuestUITypeToString(type),
                    linksFlutter ? @"是" : @"否",
                    hasUIApplicationMain ? @"是" : @"否",
                    hasAppMain ? @"是" : @"否",
                    hasChainedFixups ? @"是" : @"否"] UTF8String]);
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
