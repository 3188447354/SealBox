//
//  SBGuestLoader.h
//  Sealbox
//
//  客加载器：证书门 → 读选中客 App → 重起请求 → 新进程内搭环境、dlopen、跳入口。
//  STUB：脚手架先行版（只留接口、永不启动客 App）；完整实现由 GuestLoader 模块替换。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SBGuestLoader : NSObject

+ (instancetype)shared;

/// 是否有未处理的“进客 App”启动请求（选中标记 + 收据都在）。
+ (BOOL)isGuestLaunchRequested;

/// 请求启动客 App：证书门 → 写选中标记与收据 → 发重起请求 → 进程重起。
/// completion 在请求发出（或立即失败）时回调；error 带阶段名。
- (void)requestGuestLaunchWithBundleID:(NSString *)bundleID
                        containerUUID:(NSString *)containerUUID
                           completion:(void (^)(NSError *_Nullable error))completion;

/// 新进程启动时调用：若有启动请求，读收据、加载客 App；成功返回 YES。
- (BOOL)launchGuestIfRequested;

/// 当前进程是否已启用 JIT（CS_DEBUGGED 标志，或越狱环境）。
+ (BOOL)isJITEnabled;

/// 启动链自测（F1）：用导入证书签一个测试件并校验签名是否被系统认可。
+ (BOOL)runSelfTestWithCertificate:(NSData *)p12
                          password:(NSString *)pass
                             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
