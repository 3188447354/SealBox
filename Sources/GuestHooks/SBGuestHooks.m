//
//  SBGuestHooks.m
//  Sealbox
//
//  客端 Hook 库：随客 App 一起加载的 dylib。
//  STUB：脚手架先行版（constructor 空实现）；完整实现由 GuestHooks 模块替换。
//

#import <Foundation/Foundation.h>

__attribute__((constructor))
static void SBGuestHooksInit(void) {
    // STUB：完整 Hook（UserDefaults、钥匙串、文件管理、横杠返回）由 GuestHooks 模块实现。
}
