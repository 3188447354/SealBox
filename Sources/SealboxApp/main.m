// main.m — 进程入口（0.2.25）。
//
// LC 的做法（已在本地 LC 源码里核实，不是猜测）：客 App 的 UIApplicationMain
// 必须是一个进程里的第一遍——LC 从不 hook 它。LC 的用户点图标后，runApp
// 把 selected/selectedContainer 写进 UserDefaults，再用 LSApplicationWorkspace
// 把自己重新打开一遍、SIGKILL 自杀（LiveContainer/LCSharedUtils.m
// launchToGuestAppWithClassicMode）；新进程的 LiveContainerMain 在 UIKit
// 启动之前就看 selected，有则直接 dlopen 客、跳客 main（LiveContainer/
// LCBootstrap.m），没选才 dlopen LiveContainerSwiftUI 跑宿主界面。客 main
// 返回后 LC 记错并退出，不进宿主 UI。
//
// SealBox 的点图标启动 0.2.26 是重起进程（收据 + sealbox-launch:// URL +
// exit(0)），缺的只是“新进程别先起 SwiftUI”：0.2.24 之前新进程先跑
// SealboxApp.main()（第一遍 UIApplicationMain），再在 onAppear 里加载客 App，
// 客再调 UIApplicationMain 就是第二遍——nread 0.2.24 崩溃：
// UIApplicationInstantiateSingleton 抛 NSException + Dispatch queue already
// set（崩溃文件 ~/workspace/user/files/SealBox-2026-11-20-180007.ips）。
// 所以 @main 从 SealboxApp.swift 移走，入口改到这里：收据就绪且预检通过时
// 在 UIKit 启动之前直接加载客 App；其余情况起宿主 SwiftUI（SBHostAppMain），
// 由启动路由接手（需要修复时走异步修复，0.2.27：修完进程内加载，不再重起）。
// 0.2.27：点图标走进程内加载（拦截客的第二遍 UIApplicationMain），
// 本文件的 preflight 直接加载只留作主前置路（MJ 手动重开等遗留收据场景）。
#import <Foundation/Foundation.h>
#import <dlfcn.h>

#import "SBGuestLoader.h"
#import "SBGuestBootstrap.h"
#import "SBDiagLog.h"
#import "SealBox-Swift.h"

extern void SBHostAppMain(void);

// 0.2.26 G6：LC 同款（LCBootstrap.m:655-663）——未捕获异常处理器：把
// reason + 调用栈写进 App Group defaults 的 SBLastLaunchError 键，
// 下次进宿主 UI 时弹一次（见 SealboxApp.showLastLaunchErrorIfNeeded）。
// 客的 NSSetUncaughtExceptionHandler 已被 hook 成空操作（G5），所以这里
// 是进程里唯一的未捕获异常处理器。
static void SBUncaughtExceptionHandler(NSException *exception) {
    @try {
        NSString *reason = exception.reason ?: @"（无 reason）";
        NSString *stack = [[exception callStackSymbols] componentsJoinedByString:@"\n"];
        NSString *text = [NSString stringWithFormat:@"%@\nCall stack:\n%@", reason, stack];
        NSString *suiteName = [@"group." stringByAppendingString:
            ([[NSBundle mainBundle] bundleIdentifier] ?: @"com.mjorb.sealbox")];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        [defaults setObject:text forKey:@"SBLastLaunchError"];
        [defaults synchronize];
        SBDiagLogLine([[NSString stringWithFormat:@"未捕获异常：%@", reason] UTF8String]);
    } @catch (NSException *ignored) {
        (void)ignored;
    }
}

int main(int argc, char *argv[]) {
    SBDiagLogBeginRun();
    // 0.2.26 G6：见文件头——进程一启动就装未捕获异常处理器。
    NSSetUncaughtExceptionHandler(SBUncaughtExceptionHandler);
    // 0.2.26 G7：LC 同款（main.c）——先读 $HOME/Library/preloadLibraries.txt，
    // 逐行 dlopen（RTLD_LAZY|RTLD_GLOBAL），读完删文件；失败只记日志。
    // 文件由 SBAppCoordinator.launchGuestInProcess 在 iOS 26+ 且客带 MetalANGLE 时写。
    {
        NSString *preloadPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/preloadLibraries.txt"];
        NSString *preloadContent = [NSString stringWithContentsOfFile:preloadPath encoding:NSUTF8StringEncoding error:nil];
        if (preloadContent) {
            for (NSString *line in [preloadContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                NSString *lib = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (lib.length == 0) {
                    continue;
                }
                if (!dlopen([lib UTF8String], RTLD_LAZY | RTLD_GLOBAL)) {
                    const char *dlErr = dlerror();
                    SBDiagLogLine([[NSString stringWithFormat:@"预加载库失败：%@（%@）", lib, dlErr ? [NSString stringWithUTF8String:dlErr] : @"?"] UTF8String]);
                } else {
                    SBDiagLogLine([[NSString stringWithFormat:@"预加载库：%@", lib] UTF8String]);
                }
            }
            [[NSFileManager defaultManager] removeItemAtPath:preloadPath error:nil];
        }
    }
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *shortVersion = info[@"CFBundleShortVersionString"];
    if (![shortVersion isKindOfClass:[NSString class]]) {
        shortVersion = @"?";
    }
    NSString *build = info[@"CFBundleVersion"];
    if (![build isKindOfClass:[NSString class]]) {
        build = @"?";
    }
    SBDiagLogLine([[NSString stringWithFormat:@"进程启动 %@（%@）", shortVersion, build] UTF8String]);

    if ([SBGuestLoader isGuestLaunchRequested]) {
        // 预检（SBGuestLaunchPreflight）：0 = 无客启动请求或预检不通过，
        // 1 = 可直接在 main 里加载客 App，2 = 需要修复。
        NSInteger preflight = [SBGuestLaunchPreflight preflight];
        if (preflight == 1) {
            SBDiagLogLine("客启动：预检通过，UIKit 启动前直接加载客 App");
            BOOL loaded = [[SBGuestLoader shared] launchGuestIfRequested];
            if (loaded) {
                // 客 main 跑完返回（LC 同款：记下就退出，不进宿主 UI——
                // 客若调过 UIApplicationMain，再起宿主 UI 就是第二遍）。
                SBDiagLogLine("客 App 已退出（main 返回），进程退出");
                return 0;
            }
            // 加载失败：收据已是 guest-failed；进宿主 UI，由启动路由按收据弹错。
            // 先补记一次上次启动结果，否则“上次签名失败”标记永远不更新。
            [SBGuestLaunchPreflight noteGuestLoadFailedIfNeeded];
            SBDiagLogLine("客加载失败（main 前置路），进宿主界面弹错");
        } else if (preflight == 2) {
            SBDiagLogLine("客启动：需先修复，进宿主界面走异步修复（修完再重起）");
        } else {
            SBDiagLogLine("客启动：预检不通过，进宿主界面");
        }
    }

    // 0.2.26 G4b：LC 同款（LCBootstrap.m:830-848）——客跑过 WebKit 后宿主的
    // Library/Cookies 是指到客容器的软链、真身在 Cookies2；进宿主界面前移回来。
    {
        NSString *homeLibrary = [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
        NSString *cookies2Path = [homeLibrary stringByAppendingPathComponent:@"Cookies2"];
        NSString *cookiesPath = [homeLibrary stringByAppendingPathComponent:@"Cookies"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:cookies2Path]) {
            [fm removeItemAtPath:cookiesPath error:nil];
            [fm moveItemAtPath:cookies2Path toPath:cookiesPath error:nil];
            SBDiagLogLine("Cookies 已还原（Cookies2 移回）");
        }
    }

    // 0.2.37：宿主 delegate window 补丁——SwiftUI.AppDelegate 没有 window 属性，
    // UIKit scene 机制或客代码问它要 window 时会抛 unrecognized selector 杀进程
    //（0.2.36 真机启动时异常弹窗）。须在 SwiftUI 启动前装好。
    [SBGuestBootstrap installHostDelegateWindowGetter];

    // 0.2.40：0.2.38 启动崩（窗口补丁行后断）无 .ips、未证实；“窗口补丁行→
    // 读已装应用”这段原来没有任何日志行，以后崩了无法定位。在 SBHostAppMain()
    // 调用前与 App 入口内各记一行，夹住这段。
    SBDiagLogLine(@"宿主启动：窗口补丁已装，进 SBHostAppMain");
    SBHostAppMain();
    return 0;
}
