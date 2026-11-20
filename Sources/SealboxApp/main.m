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
// SealBox 的点图标重启本来就是重起进程（收据 + sealbox-launch:// URL +
// exit(0)），缺的只是“新进程别先起 SwiftUI”：0.2.24 之前新进程先跑
// SealboxApp.main()（第一遍 UIApplicationMain），再在 onAppear 里加载客 App，
// 客再调 UIApplicationMain 就是第二遍——nread 0.2.24 崩溃：
// UIApplicationInstantiateSingleton 抛 NSException + Dispatch queue already
// set（崩溃文件 ~/workspace/user/files/SealBox-2026-11-20-180007.ips）。
// 所以 @main 从 SealboxApp.swift 移走，入口改到这里：收据就绪且预检通过时
// 在 UIKit 启动之前直接加载客 App；其余情况起宿主 SwiftUI（SBHostAppMain），
// 由启动路由接手（需要修复时走异步修复，修完再重起一次，绝不进程内加载）。
#import <Foundation/Foundation.h>

#import "SBGuestLoader.h"
#import "SBDiagLog.h"
#import "SealBox-Swift.h"

extern void SBHostAppMain(void);

int main(int argc, char *argv[]) {
    SBDiagLogBeginRun();
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

    SBHostAppMain();
    return 0;
}
