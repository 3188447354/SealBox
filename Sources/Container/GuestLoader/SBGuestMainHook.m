// SBGuestMainHook.m — 客 App 的 UIApplicationMain 拦截（0.2.27 进程内进客）。
#import "SBGuestMainHook.h"

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#import "litehook.h"
#import "SBGuestLoader.h"
#import "SBDiagLog.h"

typedef int (*SBUIApplicationMainFn)(int argc, char *argv[],
                                      NSString *principalClassName,
                                      NSString *delegateClassName);

static SBUIApplicationMainFn g_orig_UIApplicationMain = NULL;
static SBGuestMainHookContext *g_hookContext = nil;
static BOOL g_hookDidActivate = NO;
static NSError *g_hookActivationError = nil;

BOOL SBGuestMainHookDidActivate(void) {
    return g_hookDidActivate;
}

NSError * _Nullable SBGuestMainHookActivationError(void) {
    return g_hookActivationError;
}

void SBGuestMainHookResetActivationState(void) {
    g_hookDidActivate = NO;
    g_hookActivationError = nil;
}

#pragma mark - 调用方镜像（日志用：证明拦截由哪条路触发）

static NSString *SBHookCallerImageName(void) {
    void *returnAddress = __builtin_return_address(0);
    Dl_info info;
    if (dladdr(returnAddress, &info) && info.dli_fname) {
        NSString *path = [NSString stringWithUTF8String:info.dli_fname];
        return path.lastPathComponent ?: path;
    }
    return @"未知镜像";
}

#pragma mark - 拦截实现

int SBHookedUIApplicationMain(int argc, char *argv[],
                              NSString *principalClassName,
                              NSString *delegateClassName) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) {
        // 新鲜进程：第一遍 UIApplicationMain（宿主启动、或 main.m 前置路的客），
        // 原样转发。无 interposition 在场，dlsym 给的是 UIKit 真函数。
        if (!g_orig_UIApplicationMain) {
            g_orig_UIApplicationMain = (SBUIApplicationMainFn)dlsym(RTLD_DEFAULT, "UIApplicationMain");
        }
        if (g_orig_UIApplicationMain) {
            return g_orig_UIApplicationMain(argc, argv, principalClassName, delegateClassName);
        }
        SBDiagLogLine(@"拦截 UIApplicationMain：新鲜进程但找不到原函数，返回 0");
        return 0;
    }
    // 进程内：第二遍 UIApplicationMain——宿主 UIKit 已在跑，绝不能重初始化
    //（nread 0.2.24 就是死在这：Dispatch queue already set）。拦截。
    NSString *callerImage = SBHookCallerImageName();
    NSString *bundleID = g_hookContext.bundleID ?: @"未知客";
    SBDiagLogLine([[NSString stringWithFormat:
                    @"拦截 UIApplicationMain：%@ 调用方 %@，principal=%@ delegate=%@（进程内，不调原函数）",
                    bundleID, callerImage,
                    principalClassName ?: @"(nil)", delegateClassName ?: @"(nil)"] UTF8String]);
    NSError *error = nil;
    BOOL ok = [[SBGuestSessionManager sharedManager] activateGuestWithContext:g_hookContext
                                                          principalClassName:principalClassName
                                                           delegateClassName:delegateClassName
                                                                       error:&error];
    if (ok) {
        g_hookDidActivate = YES;
        return 0;
    }
    g_hookActivationError = error;
    SBDiagLogLine([[NSString stringWithFormat:@"拦截 UIApplicationMain：%@ 同步激活失败（%@）",
                    bundleID, error.localizedDescription ?: @"未知原因"] UTF8String]);
    // 不调原函数（第二遍必崩）；bootstrap 在 main 返回后读到激活失败，按加载失败处理。
    return 0;
}

#pragma mark - 安装

/// 按执行路径找客镜像头（SBGuestHookUtils.h 同款逻辑，宿主侧自带一份——
// GuestHooks target 的头宿主侧不包含）。
static const struct mach_header *SBGuestImageHeaderForExecPath(NSString *execPath) {
    const char *execPathUTF8 = [execPath UTF8String];
    if (!execPathUTF8) {
        return NULL;
    }
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strcmp(name, execPathUTF8) == 0) {
            return _dyld_get_image_header(i);
        }
    }
    NSString *execName = execPath.lastPathComponent;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && [[[NSString stringWithUTF8String:name] lastPathComponent] isEqualToString:execName]) {
            return _dyld_get_image_header(i);
        }
    }
    return NULL;
}

void SBGuestMainHookInstallForGuestImage(const struct mach_header *guestHeader,
                                         SBGuestMainHookContext *context) {
    g_hookContext = context;
    SBGuestMainHookResetActivationState();
    if (!guestHeader) {
        guestHeader = SBGuestImageHeaderForExecPath(context.guestExecPath);
    }
    if (!guestHeader) {
        SBDiagLogLine([[NSString stringWithFormat:@"拦截 UIApplicationMain：%@ 找不到客镜像头，不装拦截",
                        context.bundleID] UTF8String]);
        return;
    }
    // SwiftUI 客判定：镜像不直接引用 UIApplicationMain 时 rebind 够不着。
    if (!SBGuestImageFileReferencesUIApplicationMain(context.guestExecPath)) {
        SBDiagLogLine([[NSString stringWithFormat:
                        @"拦截 UIApplicationMain：%@ 镜像未直接引用 UIApplicationMain（疑似 SwiftUI 客，调用在 SwiftUICore 缓存里），rebind 未装上；若客闪退于第二遍 UIApplicationMain，即为此因（X2）",
                        context.bundleID] UTF8String]);
        return;
    }
    if (!g_orig_UIApplicationMain) {
        g_orig_UIApplicationMain = (SBUIApplicationMainFn)dlsym(RTLD_DEFAULT, "UIApplicationMain");
    }
    if (!g_orig_UIApplicationMain) {
        SBDiagLogLine([[NSString stringWithFormat:@"拦截 UIApplicationMain：%@ dlsym 找不到原函数，不装拦截",
                        context.bundleID] UTF8String]);
        return;
    }
    litehook_rebind_symbol(guestHeader, (void *)g_orig_UIApplicationMain,
                           (void *)SBHookedUIApplicationMain, NULL);
    SBDiagLogLine([[NSString stringWithFormat:@"拦截 UIApplicationMain：%@ 已在客镜像重绑（0.2.25 函数指针传法）",
                    context.bundleID] UTF8String]);
}

#pragma mark - 文件符号表判定（SwiftUI 客识别）

/// 读磁盘 Mach-O 的 LC_SYMTAB + LC_DYSYMTAB：未定义符号表里有没有 _UIApplicationMain。
/// 只读，不改动；符号表被剥掉/解析失败时返回 NO（按够不着处理，记警告不拦加载）。
BOOL SBGuestImageFileReferencesUIApplicationMain(NSString *guestExecPath) {
    FILE *file = fopen([guestExecPath UTF8String], "rb");
    if (!file) {
        return NO;
    }
    uint32_t magic = 0;
    if (fread(&magic, sizeof(magic), 1, file) != 1) {
        fclose(file);
        return NO;
    }
    // fat 二进制：取 arm64 切片。
    uint64_t baseOffset = 0;
    if (magic == 0xCAFEBABE || magic == 0xBEBAFECA) {
        uint32_t nfat = 0;
        BOOL swapped = (magic == 0xBEBAFECA);
        fseek(file, 4, SEEK_SET);
        if (fread(&nfat, sizeof(nfat), 1, file) != 1) {
            fclose(file);
            return NO;
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
            return NO;
        }
        fseek(file, (long)baseOffset, SEEK_SET);
        if (fread(&magic, sizeof(magic), 1, file) != 1) {
            fclose(file);
            return NO;
        }
    }
    BOOL is64 = (magic == 0xFEEDFACF);
    if (!is64 && magic != 0xFEEDFACE) {
        fclose(file);
        return NO;
    }
    uint32_t ncmds = 0;
    fseek(file, (long)(baseOffset + 16), SEEK_SET);
    if (fread(&ncmds, sizeof(ncmds), 1, file) != 1) {
        fclose(file);
        return NO;
    }
    uint64_t cursor = baseOffset + (is64 ? 32 : 28);
    uint32_t symoff = 0, nsyms = 0, stroff = 0;
    uint32_t iundefsym = 0, nundefsym = 0;
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = 0, cmdsize = 0;
        fseek(file, (long)cursor, SEEK_SET);
        if (fread(&cmd, sizeof(cmd), 1, file) != 1 ||
            fread(&cmdsize, sizeof(cmdsize), 1, file) != 1) {
            fclose(file);
            return NO;
        }
        if (cmd == 0x2) { // LC_SYMTAB
            fseek(file, (long)(cursor + 8), SEEK_SET);
            if (fread(&symoff, sizeof(symoff), 1, file) != 1 ||
                fread(&nsyms, sizeof(nsyms), 1, file) != 1 ||
                fread(&stroff, sizeof(stroff), 1, file) != 1) {
                fclose(file);
                return NO;
            }
        } else if (cmd == 0xB) { // LC_DYSYMTAB
            uint32_t fields[6] = {0};
            fseek(file, (long)(cursor + 8), SEEK_SET);
            if (fread(fields, sizeof(uint32_t), 6, file) != 6) {
                fclose(file);
                return NO;
            }
            iundefsym = fields[4];
            nundefsym = fields[5];
        }
        if (cmdsize == 0) {
            break;
        }
        cursor += cmdsize;
    }
    if (symoff == 0 || stroff == 0 || nundefsym == 0) {
        fclose(file);
        return NO;
    }
    size_t entrySize = is64 ? 16 : 12;
    BOOL found = NO;
    for (uint32_t i = iundefsym; i < iundefsym + nundefsym && i < nsyms; i++) {
        uint32_t strx = 0;
        fseek(file, (long)(baseOffset + symoff + i * entrySize), SEEK_SET);
        if (fread(&strx, sizeof(strx), 1, file) != 1) {
            break;
        }
        fseek(file, (long)(baseOffset + stroff + strx), SEEK_SET);
        char name[64] = {0};
        size_t got = fread(name, 1, sizeof(name) - 1, file);
        if (got > 0 && strcmp(name, "_UIApplicationMain") == 0) {
            found = YES;
            break;
        }
    }
    fclose(file);
    return found;
}
