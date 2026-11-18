// SBGuestHooks.m — 客端 Hook dylib 入口。
// 本 dylib 只被注入客可执行文件，所以天然只在客 App 进程上下文中运行；
// 另加一道环境变量守卫：被加载进非客进程时 SB_GUEST_BUNDLE_ID 不存在，
// constructor 直接返回，不装任何 Hook、不影响宿主。
#import <Foundation/Foundation.h>
#import <stdlib.h>

extern void SBUserDefaultsHookInstall(void);
extern void SBSecItemHookInstall(void);
extern void SBFileManagerHookInstall(void);
extern void SBHomeBarOverlayInstall(void);

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
    });
}
