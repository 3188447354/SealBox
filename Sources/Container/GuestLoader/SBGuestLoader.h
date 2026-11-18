// SBGuestLoader.h — 客加载器总入口：证书门、重启请求（带 5 秒看门狗）、
// 重启后读收据加载客 App、JIT 检测、启动链自测。全部报错带中文阶段名。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 错误 domain。userInfo 里 SBGuestLoaderErrorStageKey 对应中文阶段名
///（证书检查 / 重启请求 / 加载客 App / 自测），localizedDescription 为中文错误文案。
extern NSString * const SBGuestLoaderErrorDomain;
extern NSString * const SBGuestLoaderErrorStageKey;

typedef NS_ENUM(NSInteger, SBGuestLoaderErrorCode) {
    SBGuestLoaderErrorMissingCertificate   = 1001, // 未导入证书
    SBGuestLoaderErrorCertificateDeleted   = 1002, // 证书已被删除
    SBGuestLoaderErrorRestartRequestFailed = 1003, // 系统没有重启应用
    SBGuestLoaderErrorGuestLoadFailed      = 1004, // 客 App 加载失败
    SBGuestLoaderErrorBundleNotFound       = 1005, // 找不到客 App 安装包
    SBGuestLoaderErrorUnsupportedBinary    = 1006, // 不支持的二进制（如 32 位）
    SBGuestLoaderErrorSpoofFailed          = 1007, // 伪装主 Bundle / 可执行路径失败
    SBGuestLoaderErrorEntryPointNotFound   = 1008, // 找不到客 App 入口
    SBGuestLoaderErrorSelfTestFailed       = 1009, // 启动链自测失败
    SBGuestLoaderErrorCertificateExpired   = 1010, // 证书已过期（缓存过期日 < 现在）
};

/// 构造一个带中文阶段名与中文文案的错误。recoverySuggestion 可为空。
NSError *SBGuestLoaderErrorMake(SBGuestLoaderErrorCode code,
                                NSString *stage,
                                NSString *message,
                                NSString * _Nullable recoverySuggestion);

@interface SBGuestLoader : NSObject

+ (instancetype)shared;

/// 当前进程启动是否由一次客启动请求触发：selection 与收据同时存在，
// 且收据阶段为 restart-requested 或 restart-confirmed。
+ (BOOL)isGuestLaunchRequested;

/// 请求启动客 App：证书门 → 写 selection 与收据（restart-requested）→
/// openURL(sealbox-launch://guest?...) → completion 成功后延迟 exit(0)。
/// 若 5 秒内进程仍活着（重启请求被系统丢弃），completion 回
/// SBGuestLoaderErrorRestartRequestFailed（阶段：重启请求）。
/// completion 只调用一次，总在主线程回调。
/// - Parameters:
///   - diskDirectoryName: 客 App 在磁盘上的目录名（平行安装带时间戳后缀；
///     为空时按 <bundleID>.app 处理）。
///   - keychainGroup: 该客 App 的钥匙串组号（0..<128），写进收据供新进程用。
- (void)requestGuestLaunchWithBundleID:(NSString *)bundleID
                        containerUUID:(NSString *)containerUUID
                    diskDirectoryName:(NSString *)diskDirectoryName
                        keychainGroup:(NSInteger)keychainGroup
                           completion:(void (^)(NSError * _Nullable error))completion;

/// 新进程启动时调用：读收据；阶段为 restart-requested 时先把收据写成
/// restart-confirmed，再调 SBGuestBootstrap 加载客 App。
/// 加载成功返回 YES（客 App 的 main 已跑过并返回，宿主应继续进桌面）；
/// 无请求或加载失败返回 NO。失败时收据写成 guest-failed（带中文原因），
/// selection 已清掉，宿主进桌面后应按收据弹错并记 lastLaunchResult。
- (BOOL)launchGuestIfRequested;

/// JIT 是否已启用：/usr/lib/systemhook.dylib 可读（越狱）即 YES；
/// 否则用 csops 读码签标志，CS_DEBUGGED 置位即 YES。
+ (BOOL)isJITEnabled;

/// 启动链自测（F1，不依赖任何客 App）：
/// ① 收据读写自检；② 证书链自检——把 SBGuestHooks.dylib 复制到 tmp，
/// 用给定证书签名，再 dlopen 验证。
/// 失败时 error 带中文原因（阶段：自测 或 证书检查）。
/// 注意：内部用信号量等 ZSign 异步回调，请在后台线程调用，不要在主线程调用。
+ (BOOL)runSelfTestWithCertificate:(NSData *)p12
                          password:(NSString *)pass
                             error:(NSError **)error;

#pragma mark - 内部辅助（供 SBGuestBootstrap 与宿主入口使用，Desktop 不直接调）

/// App Group UserDefaults（suite = "group." + 宿主 Bundle ID）。
+ (NSUserDefaults *)sharedDefaults;
+ (NSString *)appGroupSuiteName;

/// 当前启动收据（SBLaunchReceipt 的 JSON 解码结果），没有则返回 nil。
+ (nullable NSDictionary *)currentLaunchReceipt;

/// 把当前收据的阶段改成 stage（保留 requestID 等其他字段），detail 写入 stageDetail。
+ (void)markReceiptStage:(NSString *)stage detail:(nullable NSString *)detail;

/// 清掉 selection（SBSelectedGuestBundleID / SBSelectedGuestContainer）与收据。
+ (void)clearLaunchRequest;

@end

NS_ASSUME_NONNULL_END
