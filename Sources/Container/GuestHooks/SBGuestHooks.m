// SBGuestHooks.m — 客端 Hook dylib 入口。
// 本 dylib 只被注入客可执行文件，所以天然只在客 App 进程上下文中运行；
// 另加一道环境变量守卫：被加载进非客进程时 SB_GUEST_BUNDLE_ID 不存在，
// constructor 直接返回，不装任何 Hook、不影响宿主。
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <dlfcn.h>

#import "litehook.h"

extern void SBUserDefaultsHookInstall(void);
extern void SBSecItemHookInstall(void);
extern void SBFileManagerHookInstall(void);
extern void SBHomeBarOverlayInstall(void);
extern void SBDocumentPickerHookInstall(void);

// 0.2.26 G5：LC 同款（LCBootstrap.m:523）——客的未捕获异常处理器会被
// NSSetUncaughtExceptionHandler 换成空操作，异常处理器由 main.m 统一管
//（写 SBLastLaunchError 键，下次进 UI 展示）。客自己的处理器留着会和
// 宿主的崩溃记录打架，还可能把客的崩溃吞掉不报。
static void SBHooked_NSSetUncaughtExceptionHandler_doNothing(void) {
}

__attribute__((constructor)) static void SBGuestHooksInit(void) {
    if (getenv("SB_GUEST_BUNDLE_ID") == NULL) {
        return;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SBUserDefaultsHookInstall();
        SBSecItemHookInstall();
        SBFileManagerHookInstall();
        SBHomeBarOverlayInstall();
        SBDocumentPickerHookInstall();
        // 0.2.26 G5：见文件头——LITEHOOK_REBIND_GLOBAL 即 NULL（litehook.h）。
        void *orig = dlsym(RTLD_DEFAULT, "NSSetUncaughtExceptionHandler");
        if (orig) {
            litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, orig,
                                   (void *)SBHooked_NSSetUncaughtExceptionHandler_doNothing, NULL);
        }
    });
}
