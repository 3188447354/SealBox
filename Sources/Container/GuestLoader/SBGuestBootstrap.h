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
///   - keychainGroup: 该客 App 的钥匙串组号（0..<128）；< 0 时按旧兜底
///     （selection 键 / 容器 UUID 哈希）处理。
+ (BOOL)loadGuestWithBundleID:(NSString *)bundleID
                containerUUID:(NSString *)containerUUID
            diskDirectoryName:(nullable NSString *)diskDirectoryName
                keychainGroup:(NSInteger)keychainGroup
                        error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
