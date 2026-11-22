// SBGuestBootstrap.h — 客 App 启动引导：搭环境、伪装、装 Hook、dlopen 并跳入口。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SBGuestBootstrap : NSObject

/// 在当前进程内加载并运行客 App。
/// 流程：搭环境（HOME/容器/tmp 软链/目录）→ 改写主 Bundle 与可执行路径 →
/// 装客端 Hook → dlopen 客可执行 → 按 LC_MAIN 的 entryoff 跳入口。
/// 客 App 的 main 返回后（即客 App 退出），恢复可执行路径、清掉启动标记并返回 YES，
/// 宿主继续进桌面；任一步失败返回 NO，error 带中文阶段名与原因。
/// 注意：调用前收据应已是 restart-confirmed；成功跳入客入口前收据会写成 guest-loaded。
/// - Parameters:
///   - diskDirectoryName: 客 App 在磁盘上的目录名（平行安装带时间戳后缀；
///     为空时按 <bundleID>.app 处理）。
///   - keychainGroup: 该客 App 的钥匙串组号（0..<128）；< 0 时按记录回查
///     （selection 键 → 安装记录）；哈希兜底只留给无记录可查的极端情形
///     （0.2.44：只认记录，不哈希兜底）。
+ (BOOL)loadGuestWithBundleID:(NSString *)bundleID
                containerUUID:(NSString *)containerUUID
            diskDirectoryName:(nullable NSString *)diskDirectoryName
                keychainGroup:(NSInteger)keychainGroup
                        error:(NSError **)error;

/// 进程内加载（0.2.27）：与 loadGuestWithBundleID 同流程，但在 dlopen 后、
// 跳 main 前装好 UIApplicationMain 拦截（SBGuestMainHook）；hook 激活后客
// main 返回≠退出，不恢复环境、不清收据（激活时会话侧已记成功），返回 YES
// 表示客已在前台。调用方是宿主 UI（UIKit 已在跑），绝不用于 main.m 前置路。
+ (BOOL)loadGuestInProcessWithBundleID:(NSString *)bundleID
                         containerUUID:(NSString *)containerUUID
                     diskDirectoryName:(nullable NSString *)diskDirectoryName
                         keychainGroup:(NSInteger)keychainGroup
                                 error:(NSError **)error;

/// 应用客上下文（原 loadGuest 步骤 2–5b，0.2.27 抽出）：数据容器/HOME/env、
// 主 Bundle 伪装、可执行路径、进程身份。首次加载与会话恢复共用；
// 失败时还原已应用的部分并返回 NO。
/// keychainGroup 由调用方先解析好再传（收据/选择键/容器哈希三档）。
/// 成功时 guestBundleOut 回填客 Bundle（恢复时重伪装用）。
+ (BOOL)applyGuestContextForBundleID:(NSString *)bundleID
                       guestAppPath:(NSString *)guestAppPath
                      guestExecPath:(NSString *)guestExecPath
                      containerPath:(NSString *)containerPath
                      keychainGroup:(NSInteger)keychainGroup
                              error:(NSError **)error
                   guestBundleOut:(NSBundle **)guestBundleOut;

/// 把进程上下文还原成宿主自己的（伪装/路径/身份/HOME/env）。各还原函数自带
/// “未改写过即空操作”守卫，重复调无害。
+ (void)restoreHostContext;

/// 0.2.37：给宿主 delegate（SwiftUI.AppDelegate）补 window 属性——0.2.36 真机
/// 启动时异常弹窗 -[SwiftUI.AppDelegate window]: unrecognized selector。
/// 全仓查过：我们代码里没有任何一处直接发 delegate.window（0.2.36 的 storyboard
/// 建窗路也是自己建 UIWindow、不读 delegate.window），发送方是 UIKit 的 scene
/// 机制或客代码在宿主 delegate 在位时问它要 window；SwiftUI.AppDelegate 没有
/// window 属性就直接抛异常杀进程。修法：运行时给该类补一个 window getter
/// （返回当前 keyWindow）与 setter（收到的窗变 key 可见，即 legacy 语义），
/// 类身份不变（isKindOfClass 照常），Apple 将来若补了该方法则 class_addMethod
/// 返回 NO、不覆盖。幂等，多调无害。
+ (void)installHostDelegateWindowGetter;

@end

NS_ASSUME_NONNULL_END
