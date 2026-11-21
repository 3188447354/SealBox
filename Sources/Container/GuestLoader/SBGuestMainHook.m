// SBGuestMainHook.m — 客 App 的 UIApplicationMain 拦截（0.2.27 进程内进客）。
#import "SBGuestMainHook.h"

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <string.h>

#import "SBChainedFixupRebind.h"
#import "SBGuestLoader.h"
#import "SBDiagLog.h"

// Swift 覆盖层 UIApplicationMain 的替身（SBSwiftUIEmbed.swift，@_cdecl 导出）。
// 它的参数是 Swift 覆盖层签名的 ABI（Int32，argv 指针，String?，String?）；
// 此签名的 Swift 调用约定与 C 一致（Int32→w0，指针→x1，16 字节 String?→x2:x3
// 与 x4:x5，返回 Int32→w0），ObjC 侧只取地址写进客 __got 槽，不直接调它，
// 故声明成 void 函数取地址。
extern void SBHookedSwiftUIApplicationMain(void);

/// C 符号：ObjC main.m 直接调 UIApplicationMain。
static const char * const SBUIApplicationMainCSymbol = "_UIApplicationMain";
/// Swift 覆盖层符号：Swift @main / @UIApplicationMain 生成的 main 调
/// UIKit.UIApplicationMain（mangled 全名；签名自 Swift 5 起未变）。
/// 原型 0230（OmoFun Runner 实测）：链式 import 序号 41，__DATA_CONST 槽
/// 0x8150，指针格式 6（无 PAC）。
static const char * const SBUIApplicationMainSwiftSymbol =
    "_$s5UIKit17UIApplicationMainys5Int32VAD_SpySpys4Int8VGGSgSSSgAJtF";

typedef int (*SBUIApplicationMainFn)(int argc, char * _Nullable * _Nullable argv,
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

int SBHookedUIApplicationMain(int argc, char * _Nullable * _Nullable argv,
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
            SBDiagLogLine([[NSString stringWithFormat:
                            @"拦截 UIApplicationMain：新鲜进程第一遍（调用方 %@），原样转发",
                            SBHookCallerImageName()] UTF8String]);
            return g_orig_UIApplicationMain(argc, argv, principalClassName, delegateClassName);
        }
        SBDiagLogLine([@"拦截 UIApplicationMain：新鲜进程但找不到原函数，返回 0" UTF8String]);
        return 0;
    }
    // 进程内：第二遍 UIApplicationMain——宿主 UIKit 已在跑，绝不能重初始化
    //（nread 0.2.24 与 0.2.29 就是死在这：Dispatch queue already set）。拦截。
    if (g_hookDidActivate) {
        // 多镜像重绑时同一替身可能被调两次（主镜像＋Framework 各一个槽）：
        // 第一次已激活，第二次直接返回 0，不重复激活（0.2.30）。
        SBDiagLogLine([@"拦截 UIApplicationMain：已激活过，直接返回 0（重复触发）" UTF8String]);
        return 0;
    }
    NSString *callerImage = SBHookCallerImageName();
    NSString *bundleID = g_hookContext.bundleID ?: @"未知客";
    SBDiagLogLine([[NSString stringWithFormat:
                    @"拦截 UIApplicationMain：%@ 调用方 %@，principal=%@ delegate=%@（进程内第二遍，不调原函数）",
                    bundleID, callerImage,
                    principalClassName ?: @"(nil)", delegateClassName ?: @"(nil)"] UTF8String]);
    NSError *error = nil;
    BOOL ok = [[SBGuestSessionManager sharedManager] activateGuestWithContext:g_hookContext
                                                          principalClassName:principalClassName
                                                           delegateClassName:delegateClassName
                                                                       error:&error];
    if (ok) {
        g_hookDidActivate = YES;
        // 0.2.32：这里只表示“拦截完成、scene 驱动已安排”，不是“客窗已出现”——
        // 客窗出现由会话管理器的 completeActivation（“已激活（客窗 …）”）记。
        // 0.2.31 phoenix 三回都在这行之后、0.4 秒补查之前死了进程，旧文案
        // “会话激活成功”会让人误以为客已在前台；改名，不在窗出现前记成功。
        SBDiagLogLine([[NSString stringWithFormat:@"拦截 UIApplicationMain：%@ 拦截完成，已安排 scene 驱动（客窗待出现，0.4 秒后补查）",
                        bundleID] UTF8String]);
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

/// 客包 Frameworks 目录下各 Framework 的可执行文件路径
///（<Name>.framework/<Name>）。只列磁盘上存在的文件；加载与否由调用方按
/// dyld 镜像头判定。
static NSArray<NSString *> *SBGuestFrameworkExecutablePaths(NSString *guestAppPath) {
    if (guestAppPath.length == 0) {
        return @[];
    }
    NSString *frameworksDir = [guestAppPath stringByAppendingPathComponent:@"Frameworks"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *listError = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:frameworksDir error:&listError];
    if (!entries) {
        return @[];
    }
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *entry in entries) {
        if (![entry hasSuffix:@".framework"]) {
            continue;
        }
        NSString *name = [entry stringByDeletingPathExtension];
        NSString *execPath = [[frameworksDir stringByAppendingPathComponent:entry]
                              stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:execPath]) {
            [paths addObject:execPath];
        }
    }
    return paths;
}

/// 在一个镜像里试两种符号（C 符号在前、Swift 覆盖层符号在后），任一装上
/// 即记一行并返回 YES。重绑函数自带逐槽诊断（序号/槽地址/失败原因），这里
/// 只记“试了哪个镜像、哪个符号、结果”。
static BOOL SBGuestTryRebindInImage(const struct mach_header *header,
                                    NSString *execPath,
                                    NSString *bundleID) {
    BOOL installed = NO;
    if (SBRebindGuestSymbolForImage(header, execPath, SBUIApplicationMainCSymbol,
                                    (void *)SBHookedUIApplicationMain)) {
        SBDiagLogLine([[NSString stringWithFormat:@"拦截 UIApplicationMain：%@ C 符号已在 %@ 重绑",
                        bundleID, execPath.lastPathComponent] UTF8String]);
        installed = YES;
    } else {
        SBDiagLogLine([[NSString stringWithFormat:@"拦截 UIApplicationMain：%@ %@ 无 C 符号槽（见上文链式重绑诊断）",
                        bundleID, execPath.lastPathComponent] UTF8String]);
    }
    if (SBRebindGuestSymbolForImage(header, execPath, SBUIApplicationMainSwiftSymbol,
                                    (void *)SBHookedSwiftUIApplicationMain)) {
        SBDiagLogLine([[NSString stringWithFormat:@"拦截 UIApplicationMain：%@ Swift 覆盖层符号已在 %@ 重绑",
                        bundleID, execPath.lastPathComponent] UTF8String]);
        installed = YES;
    } else {
        SBDiagLogLine([[NSString stringWithFormat:@"拦截 UIApplicationMain：%@ %@ 无 Swift 覆盖层符号槽（见上文链式重绑诊断）",
                        bundleID, execPath.lastPathComponent] UTF8String]);
    }
    return installed;
}

BOOL SBGuestMainHookInstallForGuestImage(const struct mach_header *guestHeader,
                                         SBGuestMainHookContext *context,
                                         SBGuestUIType uiType) {
    g_hookContext = context;
    SBGuestMainHookResetActivationState();
    NSString *bundleID = context.bundleID ?: @"未知客";
    NSString *typeString = SBGuestUITypeToString(uiType);
    if (!guestHeader) {
        guestHeader = SBGuestImageHeaderForExecPath(context.guestExecPath);
    }
    if (!guestHeader) {
        SBDiagLogLine([[NSString stringWithFormat:@"拦截 UIApplicationMain：%@ 找不到客镜像头，不装拦截（客类型 %@）",
                        bundleID, typeString] UTF8String]);
        return NO;
    }
    SBDiagLogLine([[NSString stringWithFormat:@"拦截 UIApplicationMain：%@ 开始装拦截（客类型 %@，主镜像 %@）",
                    bundleID, typeString, context.guestExecPath.lastPathComponent] UTF8String]);
    // ① 主镜像：调用点只可能在入口镜像里（客 main 在此）；两种符号各试一次。
    BOOL installed = SBGuestTryRebindInImage(guestHeader, context.guestExecPath, bundleID);
    // ② 主镜像没装上时扫客 Frameworks：调用若在 Framework 里，拦截点跟过去
    //（实测 Flutter 的调用在主镜像，这里是兜底；只扫已加载的镜像——链式路
    // 要内存头算 slide，未加载的记一行跳过，不强行 dlopen）。
    NSUInteger frameworkCount = 0;
    if (!installed) {
        NSArray<NSString *> *frameworkPaths =
            SBGuestFrameworkExecutablePaths(context.guestAppPath);
        frameworkCount = frameworkPaths.count;
        SBDiagLogLine([[NSString stringWithFormat:@"拦截 UIApplicationMain：%@ 主镜像未装上，扫客 Frameworks（%lu 个）",
                        bundleID, (unsigned long)frameworkCount] UTF8String]);
        for (NSString *fwExecPath in frameworkPaths) {
            const struct mach_header *fwHeader =
                SBGuestImageHeaderForExecPath(fwExecPath);
            if (!fwHeader) {
                SBDiagLogLine([[NSString stringWithFormat:@"拦截 UIApplicationMain：%@ Framework %@ 未加载，跳过",
                                bundleID, fwExecPath.lastPathComponent] UTF8String]);
                continue;
            }
            if (SBGuestTryRebindInImage(fwHeader, fwExecPath, bundleID)) {
                installed = YES;
            }
        }
    }
    if (installed) {
        SBDiagLogLine([[NSString stringWithFormat:@"拦截 UIApplicationMain：%@ 安装成功（客类型 %@）",
                        bundleID, typeString] UTF8String]);
    } else {
        // 失败原因写真实查找结果：客类型、扫了哪些镜像、两种符号都没槽——
        // 绝不再把 Flutter/UIKit 客标成“疑似 SwiftUI 客”（0.2.29 的误标）。
        SBDiagLogLine([[NSString stringWithFormat:@"拦截 UIApplicationMain：%@ 安装失败（客类型 %@，主镜像＋%lu 个 Framework 均无 C/Swift 符号槽，见上文链式重绑诊断；护栏将干净失败，不跳 main）",
                        bundleID, typeString, (unsigned long)frameworkCount] UTF8String]);
    }
    return installed;
}
