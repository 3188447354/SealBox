// SBGuestHooks.m — 客端 Hook dylib 入口。
// 本 dylib 只被注入客可执行文件，所以天然只在客 App 进程上下文中运行；
// 另加一道环境变量守卫：被加载进非客进程时 SB_GUEST_BUNDLE_ID 不存在，
// constructor 直接返回，不装任何 Hook、不影响宿主。
//
// 0.2.27：多客常驻——constructor 只在首次 dlopen 跑；第二客起由宿主在 dlopen 后
// 经 dlsym 调 SBGuestHooksInstallForGuest() 补装 per-guest 的重绑（SecItem /
// FileManager 的客镜像重绑）。全局一次的部分（方法交换、G5）仍只装一次。
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <dlfcn.h>

#import "litehook.h"

extern void SBUserDefaultsHookInstall(void);
extern void SBSecItemHookInstallForGuestImage(void);
extern void SBFileManagerHookInstallForGuestImage(void);
extern void SBHomeBarOverlayInstall(void);
extern void SBDocumentPickerHookInstall(void);

// 0.2.26 G5：LC 同款（LCBootstrap.m:523）——客的未捕获异常处理器会被
// NSSetUncaughtExceptionHandler 换成空操作，异常处理器由 main.m 统一管
//（写 SBLastLaunchError 键，下次进 UI 展示）。客自己的处理器留着会和
// 宿主的崩溃记录打架，还可能把客的崩溃吞掉不报。
static void SBHooked_NSSetUncaughtExceptionHandler_doNothing(void) {
}

/// per-guest 安装入口（0.2.27）：constructor 调一次；宿主在每次 dlopen 客后
/// 经 dlsym 再调（幂等——全局一次的部分只装一次，客镜像重绑按执行路径去重）。
/// 必须在客环境变量（SB_GUEST_*）已设好时调——constructor 在 dlopen 内跑，
/// 环境变量由宿主在 dlopen 前写好；宿主调时环境变量仍是该客的值。
void SBGuestHooksInstallForGuest(void) {
    if (getenv("SB_GUEST_BUNDLE_ID") == NULL) {
        return;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SBUserDefaultsHookInstall();
        SBDocumentPickerHookInstall();
        // 0.2.26 G5：见文件头——LITEHOOK_REBIND_GLOBAL 即 NULL（litehook.h）。
        void *orig = dlsym(RTLD_DEFAULT, "NSSetUncaughtExceptionHandler");
        if (orig) {
            litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, orig,
                                   (void *)SBHooked_NSSetUncaughtExceptionHandler_doNothing, NULL);
        }
    });
    // per-guest：SecItem / FileManager 的客镜像重绑（各文件内按执行路径去重）。
    SBSecItemHookInstallForGuestImage();
    SBFileManagerHookInstallForGuestImage();
    SBHomeBarOverlayInstall();
}

__attribute__((constructor)) static void SBGuestHooksInit(void) {
    if (getenv("SB_GUEST_BUNDLE_ID") == NULL) {
        return;
    }
    SBGuestHooksInstallForGuest();
}
