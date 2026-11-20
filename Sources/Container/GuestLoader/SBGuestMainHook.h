// SBGuestMainHook.h — 客 App 的 UIApplicationMain 拦截（0.2.27 进程内进客）。
//
// 机制：dlopen 客可执行后、跳客 main 前，用 litehook 把客镜像里
// UIApplicationMain 的懒绑定槽（__la_symbol_ptr）重绑到 SBHookedUIApplicationMain
//（与 SecItem/FileManager 同款函数指针传法，0.2.25 实证）。
// 判别器：[UIApplication sharedApplication]==nil 时是新鲜进程里的第一遍
// UIApplicationMain（宿主启动、或 main.m 前置路），原样转发；非空时是进程内
// 的第二遍（宿主 UIKit 已在跑），拦截并走会话激活，返回 0，不跑第二遍 runloop。
//
// SwiftUI 客：调用点在 SwiftUICore（共享缓存）里，客镜像不直接引用
// UIApplicationMain，rebind 够不着——安装时先按文件符号表判定，够不着时
// 记一行警告、不拦加载（X2 已知缺口，见 build log 0.2.27 节）。
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>

#import "SBGuestSessionManager.h"

NS_ASSUME_NONNULL_BEGIN

/// 在客镜像里重绑 UIApplicationMain（只在进程内加载路调用；新鲜进程路不装）。
/// context 由 bootstrap 在 dlopen 后填好，hook 触发时传给会话激活。
void SBGuestMainHookInstallForGuestImage(const struct mach_header *guestHeader,
                                         SBGuestMainHookContext *context);

/// 拦截后的替代实现（litehook 替身）。返回 0 表示客 main 可随即返回。
int SBHookedUIApplicationMain(int argc, char *argv[],
                              NSString * _Nullable principalClassName,
                              NSString * _Nullable delegateClassName);

/// 本次加载里 hook 是否已触发进程内激活（bootstrap 跳 main 后读：
// 触发过 → main 返回≠退出，不恢复环境、不清收据；未触发 → 按真退出处理）。
BOOL SBGuestMainHookDidActivate(void);

/// 同步激活失败的原因（hook 触发但激活失败时置；未触发或成功时为 nil）。
/// bootstrap 在 main 返回后读到它即按加载失败返回。
nullable NSError *SBGuestMainHookActivationError(void);

/// 每次跳 main 前复位激活状态（由 bootstrap 调）。
void SBGuestMainHookResetActivationState(void);

/// 客可执行文件（磁盘上的 Mach-O）的未定义符号表里是否含 _UIApplicationMain。
/// 够不着时（SwiftUI 客）返回 NO。只读文件，不改动。
BOOL SBGuestImageFileReferencesUIApplicationMain(NSString *guestExecPath);

NS_ASSUME_NONNULL_END
