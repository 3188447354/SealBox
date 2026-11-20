// SBGuestLoader.m — 客加载器总入口：证书门、进程内加载（0.2.27，不再重启）、
// 收据加载客 App、JIT 检测、启动链自测。
#import "SBGuestLoader.h"

#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <unistd.h>

#import "SBCodesignCheck.h"
#import "SBDiagLog.h"
#import "SBGuestBootstrap.h"
#import "SBGuestSessionManager.h"
#import "zsigner.h"

NSString * const SBGuestLoaderErrorDomain = @"com.mjorb.sealbox.GuestLoader";
NSString * const SBGuestLoaderErrorStageKey = @"SBGuestLoaderErrorStage";

// 收据阶段常量（与契约 SBLaunchReceipt.stage 一致）
static NSString * const SBReceiptStageRestartRequested = @"restart-requested";
static NSString * const SBReceiptStageRestartConfirmed = @"restart-confirmed";
static NSString * const SBReceiptStageGuestFailed      = @"guest-failed";

// UserDefaults 键（与契约 SBStore 的键一致）
static NSString * const SBKeySelectedGuestBundleID = @"SBSelectedGuestBundleID";
static NSString * const SBKeySelectedGuestContainer = @"SBSelectedGuestContainer";
static NSString * const SBKeyLaunchReceipt = @"SBLaunchReceipt";

// 证书密码的钥匙串定位（与 Swift 侧 SBKeychain 的 service / account 一致）：
// 密码自步骤 5 起只存系统钥匙串，不再写 App Group UserDefaults 明文，
// 证书门必须从钥匙串读，否则有证书也会误判成“未导入”。

// 重启截止时间（秒），与契约 restartDeadlineSeconds 一致：restart-requested
// 收据 5 秒内未兑现即过期（进程被杀后重开时，旧收据不复用）。
static const NSTimeInterval SBRestartDeadlineSeconds = 5.0;

NSError *SBGuestLoaderErrorMake(SBGuestLoaderErrorCode code,
                                NSString *stage,
                                NSString *message,
                                NSString * _Nullable recoverySuggestion) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = message;
    userInfo[SBGuestLoaderErrorStageKey] = stage;
    if (recoverySuggestion.length > 0) {
        userInfo[NSLocalizedRecoverySuggestionErrorKey] = recoverySuggestion;
    }
    return [NSError errorWithDomain:SBGuestLoaderErrorDomain code:code userInfo:userInfo];
}

@interface SBGuestLoader ()
@end

@implementation SBGuestLoader

+ (instancetype)shared {
    static SBGuestLoader *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[SBGuestLoader alloc] init];
    });
    return shared;
}

#pragma mark - App Group 与路径

+ (NSString *)appGroupSuiteName {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (bundleID.length == 0) {
        bundleID = @"com.mjorb.sealbox";
    }
    return [@"group." stringByAppendingString:bundleID];
}

+ (NSUserDefaults *)sharedDefaults {
    static NSUserDefaults *defaults = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:[self appGroupSuiteName]];
    });
    return defaults;
}

+ (NSString *)documentsDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

+ (NSString *)guestAppPathForBundleID:(NSString *)bundleID
                    diskDirectoryName:(NSString *)diskDirectoryName {
    NSString *dirName = diskDirectoryName.length > 0
        ? diskDirectoryName
        : [bundleID stringByAppendingPathExtension:@"app"];
    NSString *appsDir = [[self documentsDirectory] stringByAppendingPathComponent:@"Applications"];
    return [appsDir stringByAppendingPathComponent:dirName];
}

#pragma mark - 收据

+ (nullable NSDictionary *)currentLaunchReceipt {
    NSData *data = [[self sharedDefaults] objectForKey:SBKeyLaunchReceipt];
    if (![data isKindOfClass:[NSData class]] || data.length == 0) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return (NSDictionary *)object;
}

/// 写一条完整收据。createdAt 按 JSON 数字（自 1970 的秒数）存；Swift 侧解码时
/// 须用 JSONDecoder.dateDecodingStrategy = .secondsSince1970（默认的
/// .deferredToDate 是自 2001 年的秒数，对不上）。
/// diskDirectoryName / keychainGroup 为空（nil / -1）时不写键，读方按缺省处理。
+ (void)writeReceiptWithBundleID:(NSString *)bundleID
                   containerUUID:(NSString *)containerUUID
               diskDirectoryName:(nullable NSString *)diskDirectoryName
                   keychainGroup:(NSInteger)keychainGroup
                           stage:(NSString *)stage
                       requestID:(NSString *)requestID
                          detail:(nullable NSString *)detail {
    NSMutableDictionary *receipt = [NSMutableDictionary dictionary];
    receipt[@"requestID"] = requestID.length > 0 ? requestID : [[NSUUID UUID] UUIDString];
    receipt[@"guestBundleID"] = bundleID ?: @"";
    receipt[@"containerUUID"] = containerUUID ?: @"";
    if (diskDirectoryName.length > 0) {
        receipt[@"diskDirectoryName"] = diskDirectoryName;
    }
    if (keychainGroup >= 0) {
        receipt[@"keychainGroup"] = @(keychainGroup);
    }
    receipt[@"stage"] = stage;
    receipt[@"createdAt"] = @([[NSDate date] timeIntervalSince1970]);
    if (detail.length > 0) {
        receipt[@"stageDetail"] = detail;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:receipt options:0 error:nil];
    if (!data) {
        return;
    }
    NSUserDefaults *defaults = [self sharedDefaults];
    [defaults setObject:data forKey:SBKeyLaunchReceipt];
    [defaults synchronize];
}

+ (void)markReceiptStage:(NSString *)stage detail:(nullable NSString *)detail {
    NSDictionary *receipt = [self currentLaunchReceipt];
    NSString *bundleID = receipt[@"guestBundleID"];
    NSString *containerUUID = receipt[@"containerUUID"];
    NSString *requestID = receipt[@"requestID"];
    NSString *diskDirectoryName = receipt[@"diskDirectoryName"];
    NSInteger keychainGroup = -1;
    if ([receipt[@"keychainGroup"] isKindOfClass:[NSNumber class]]) {
        keychainGroup = [(NSNumber *)receipt[@"keychainGroup"] integerValue];
    }
    if (bundleID.length == 0 && containerUUID.length == 0) {
        return;
    }
    [self writeReceiptWithBundleID:bundleID
                     containerUUID:containerUUID
                 diskDirectoryName:diskDirectoryName
                     keychainGroup:keychainGroup
                             stage:stage
                         requestID:requestID
                            detail:detail];
}

+ (void)clearLaunchRequest {
    NSUserDefaults *defaults = [self sharedDefaults];
    [defaults removeObjectForKey:SBKeySelectedGuestBundleID];
    [defaults removeObjectForKey:SBKeySelectedGuestContainer];
    [defaults removeObjectForKey:SBKeyLaunchReceipt];
    [defaults synchronize];
}

+ (BOOL)isGuestLaunchRequested {
    NSUserDefaults *defaults = [self sharedDefaults];
    NSString *selectedBundleID = [defaults stringForKey:SBKeySelectedGuestBundleID];
    if (selectedBundleID.length == 0) {
        return NO;
    }
    NSDictionary *receipt = [self currentLaunchReceipt];
    if (!receipt) {
        return NO;
    }
    NSString *stage = receipt[@"stage"];
    if (![stage isEqualToString:SBReceiptStageRestartRequested] &&
        ![stage isEqualToString:SBReceiptStageRestartConfirmed]) {
        return NO;
    }
    // 0.2.9：restart-requested 收据过期即不算待处理——重启请求发出后 5 秒
    // 内必兑现（正常重启约 1 秒）；超时的收据是上次没兑现的旧收据（重启
    // 请求被系统丢弃、或宿主在此期间被更新/重装，包已不在当前容器里——
    // KYNS 真机实证），再拿它去加载只会多一次无谓的失败。过期收据由
    // SBLaunchRouter 的 else 分支记失败、清选中标记，不再尝试加载。
    // restart-confirmed 是本进程刚写的，不过期；createdAt 缺失时不拦
    // （按旧行为尝试加载）。
    if ([stage isEqualToString:SBReceiptStageRestartRequested]) {
        NSNumber *createdAt = receipt[@"createdAt"];
        if ([createdAt isKindOfClass:[NSNumber class]]) {
            NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - [createdAt doubleValue];
            if (age > SBRestartDeadlineSeconds) {
                return NO;
            }
        }
    }
    NSString *receiptBundleID = receipt[@"guestBundleID"];
    if (receiptBundleID.length == 0 || ![receiptBundleID isEqualToString:selectedBundleID]) {
        return NO;
    }
    return YES;
}

#pragma mark - 证书门

/// 从系统钥匙串读证书密码（service / account 与 Swift 侧 SBKeychain 一致）。
/// 读不到返回 nil，不报错。
+ (nullable NSString *)keychainCertificatePassword {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.mjorb.sealbox.certificate-password",
        (__bridge id)kSecAttrAccount: @"certificate-password",
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) {
        return nil;
    }
    NSData *data = (__bridge_transfer NSData *)result;
    if (![data isKindOfClass:[NSData class]] || data.length == 0) {
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

/// 证书门：App Group 下 Certificate.p12 存在且钥匙串里存了密码才算有证书。
/// 返回 NO 时 error 置为缺证书（两者都没有）或证书已被删除（有密码无文件）。
/// 文件与密码齐全后，再读 App Group UserDefaults 缓存的 SBCertificateExpiryDate
///（步骤 5 证书导入/刷新时写入的过期日）：有缓存且过期日 < 现在 → 证书已过期，
///拦启动（错误码 1010）。无缓存不拦——过期日未知时不误拦，证书页刷新时会更新缓存。
/// 同步 BOOL 接口做不了 OCSP 在线校验，缓存过期日是 C3 债务的本步补法。
- (BOOL)checkCertificateGate:(NSError **)error {
    NSString *password = [[self class] keychainCertificatePassword];
    BOOL hasPassword = password.length > 0;

    NSURL *groupURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:[SBGuestLoader appGroupSuiteName]];
    NSString *certPath = groupURL ? [[groupURL path] stringByAppendingPathComponent:@"Certificate.p12"] : nil;
    BOOL hasCertFile = certPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:certPath];

    if (hasCertFile && hasPassword) {
        id expiryObject = [[SBGuestLoader sharedDefaults] objectForKey:@"SBCertificateExpiryDate"];
        if ([expiryObject isKindOfClass:[NSDate class]]) {
            NSDate *expiryDate = (NSDate *)expiryObject;
            if ([expiryDate timeIntervalSinceNow] < 0) {
                if (error) {
                    *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorCertificateExpired,
                                                    @"证书检查",
                                                    @"证书已过期，请重新导入",
                                                    @"去导入证书");
                }
                return NO;
            }
        }
        return YES;
    }
    if (error) {
        if (hasPassword && !hasCertFile) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorCertificateDeleted,
                                            @"证书检查",
                                            @"证书已被删除，请重新导入",
                                            @"去设置页重新导入证书");
        } else {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorMissingCertificate,
                                            @"证书检查",
                                            @"未导入证书，请先导入证书",
                                            @"去设置页导入证书");
        }
    }
    return NO;
}

#pragma mark - 请求启动客 App

- (void)requestGuestLaunchWithBundleID:(NSString *)bundleID
                        containerUUID:(NSString *)containerUUID
                    diskDirectoryName:(NSString *)diskDirectoryName
                        keychainGroup:(NSInteger)keychainGroup
                           completion:(void (^)(NSError * _Nullable error))completion {
    if (bundleID.length == 0 || containerUUID.length == 0) {
        SBDiagLogLine([[NSString stringWithFormat:@"点图标：启动信息不完整（缺少应用或容器）：bundleID=%@ containerUUID=%@", bundleID ?: @"", containerUUID ?: @""] UTF8String]);
        if (completion) {
            completion(SBGuestLoaderErrorMake(SBGuestLoaderErrorGuestLoadFailed,
                                              @"重启请求",
                                              @"启动信息不完整，缺少应用或容器",
                                              @"请重试"));
        }
        return;
    }
    NSError *certError = nil;
    if (![self checkCertificateGate:&certError]) {
        // 0.2.10 报错日志：之前只把错交回调用方弹弹窗，诊断日志里
        // 没有这一行——证书门拦了谁、为什么拦，全看不到。
        SBDiagLogLine([[NSString stringWithFormat:@"点图标：证书门拦截：[code=%ld] %@ %@", (long)(certError ? certError.code : SBGuestLoaderErrorMissingCertificate), bundleID, certError.localizedDescription ?: @"未知原因"] UTF8String]);
        if (completion) {
            completion(certError);
        }
        return;
    }
    NSString *appPath = [SBGuestLoader guestAppPathForBundleID:bundleID
                                             diskDirectoryName:diskDirectoryName];
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:appPath isDirectory:&isDirectory] || !isDirectory) {
        SBDiagLogLine([[NSString stringWithFormat:@"点图标：包检查失败：[code=%ld] %@ %@（包不在磁盘）", (long)SBGuestLoaderErrorBundleNotFound, bundleID, appPath] UTF8String]);
        if (completion) {
            completion(SBGuestLoaderErrorMake(SBGuestLoaderErrorBundleNotFound,
                                              @"加载客 App",
                                              @"找不到客 App 安装包，请重新安装",
                                              @"重新导入该应用"));
        }
        return;
    }
    // 进程内加载必须在主线程跑（客 main 是 UIKit）。
    dispatch_async(dispatch_get_main_queue(), ^{
        [self requestGuestLaunchOnMainThreadWithBundleID:bundleID
                                           containerUUID:containerUUID
                                       diskDirectoryName:diskDirectoryName
                                           keychainGroup:keychainGroup
                                              completion:completion];
    });
}

- (void)requestGuestLaunchOnMainThreadWithBundleID:(NSString *)bundleID
                                     containerUUID:(NSString *)containerUUID
                                 diskDirectoryName:(NSString *)diskDirectoryName
                                     keychainGroup:(NSInteger)keychainGroup
                                        completion:(void (^)(NSError * _Nullable error))completion {
    // 0.2.27：进程内加载——不再发自启 URL、不再退出进程。
    // 先写 selection 与收据（当前客的记录；侧滑回桌面不清除，客 main 真退出时
    // bootstrap 清），再在当前进程内同步加载（dlopen→拦截→跳 main；hook 激活后
    // main 随即返回，客在前台运行，宿主 UIKit 的 runloop 继续驱动它）。
    NSString *requestID = [[NSUUID UUID] UUIDString];
    NSUserDefaults *defaults = [SBGuestLoader sharedDefaults];
    [defaults setObject:bundleID forKey:SBKeySelectedGuestBundleID];
    [defaults setObject:containerUUID forKey:SBKeySelectedGuestContainer];
    [SBGuestLoader writeReceiptWithBundleID:bundleID
                              containerUUID:containerUUID
                          diskDirectoryName:diskDirectoryName
                              keychainGroup:keychainGroup
                                      stage:SBReceiptStageRestartRequested
                                  requestID:requestID
                                     detail:nil];
    SBDiagLogLine([[NSString stringWithFormat:@"点图标：进程内加载 %@，已写收据", bundleID] UTF8String]);
    // 另一客在前台：先让它回后台（会话保留），再上新客。
    [[SBGuestSessionManager sharedManager] backgroundCurrentGuest];
    NSError *error = nil;
    BOOL loaded = [SBGuestBootstrap loadGuestInProcessWithBundleID:bundleID
                                                     containerUUID:containerUUID
                                                 diskDirectoryName:diskDirectoryName
                                                     keychainGroup:keychainGroup
                                                             error:&error];
    if (loaded) {
        SBDiagLogLine([[NSString stringWithFormat:@"点图标：%@ 进程内加载完成（客在前台）", bundleID] UTF8String]);
        if (completion) {
            completion(nil);
        }
        return;
    }
    NSString *message = error.localizedDescription;
    if (message.length == 0) {
        message = @"客 App 加载失败";
    }
    SBDiagLogLine([[NSString stringWithFormat:@"客加载失败：[code=%ld] %@ %@", (long)(error ? error.code : SBGuestLoaderErrorGuestLoadFailed), bundleID, message] UTF8String]);
    [SBGuestLoader markReceiptStage:SBReceiptStageGuestFailed detail:message];
    [defaults removeObjectForKey:SBKeySelectedGuestBundleID];
    [defaults removeObjectForKey:SBKeySelectedGuestContainer];
    [defaults synchronize];
    if (completion) {
        completion(error);
    }
}

/// 同步路（宿主 UIKit 已在跑）读收据、进程内加载客 App：routeOnLaunchIfNeeded
/// 的兜底——main.m 前置路被绕过时到这里。0.2.27 前这里调 launchGuestIfRequested
///（新鲜进程加载），在宿主 UI 里跳客 main 会调第二遍 UIApplicationMain 而崩
///（nread 0.2.24）；现在走进程内加载（带拦截）。
/// 加载成功返回 YES（客在前台）；无请求或加载失败返回 NO。失败时收据写成
/// guest-failed（带中文原因），selection 已清掉，宿主进桌面后应按收据弹错。
- (BOOL)launchGuestInProcessIfRequested {
    NSDictionary *receipt = [SBGuestLoader currentLaunchReceipt];
    if (!receipt) {
        return NO;
    }
    if (![[receipt objectForKey:@"stage"] isEqualToString:SBReceiptStageRestartRequested]) {
        return NO;
    }
    NSString *bundleID = receipt[@"guestBundleID"];
    NSString *containerUUID = receipt[@"containerUUID"];
    NSString *diskDirectoryName = receipt[@"diskDirectoryName"];
    NSInteger keychainGroup = -1;
    if ([receipt[@"keychainGroup"] isKindOfClass:[NSNumber class]]) {
        keychainGroup = [(NSNumber *)receipt[@"keychainGroup"] integerValue];
    }
    if (bundleID.length == 0 || containerUUID.length == 0) {
        return NO;
    }
    SBDiagLogLine([[NSString stringWithFormat:@"同步路：收到客启动请求 %@，进程内加载（宿主 UIKit 已在跑）", bundleID] UTF8String]);
    [SBGuestLoader markReceiptStage:SBReceiptStageRestartConfirmed detail:nil];
    [[SBGuestSessionManager sharedManager] backgroundCurrentGuest];
    NSError *error = nil;
    BOOL loaded = [SBGuestBootstrap loadGuestInProcessWithBundleID:bundleID
                                                     containerUUID:containerUUID
                                                 diskDirectoryName:diskDirectoryName
                                                     keychainGroup:keychainGroup
                                                             error:&error];
    if (loaded) {
        return YES;
    }
    NSString *message = error.localizedDescription;
    if (message.length == 0) {
        message = @"客 App 加载失败";
    }
    SBDiagLogLine([[NSString stringWithFormat:@"客加载失败：[code=%ld] %@ %@", (long)(error ? error.code : SBGuestLoaderErrorGuestLoadFailed), bundleID, message] UTF8String]);
    [SBGuestLoader markReceiptStage:SBReceiptStageGuestFailed detail:message];
    NSUserDefaults *defaults = [SBGuestLoader sharedDefaults];
    [defaults removeObjectForKey:SBKeySelectedGuestBundleID];
    [defaults removeObjectForKey:SBKeySelectedGuestContainer];
    [defaults synchronize];
    return NO;
}

#pragma mark - 新进程启动时加载客 App

- (BOOL)launchGuestIfRequested {
    NSDictionary *receipt = [SBGuestLoader currentLaunchReceipt];
    if (!receipt) {
        return NO;
    }
    if (![[receipt objectForKey:@"stage"] isEqualToString:SBReceiptStageRestartRequested]) {
        return NO;
    }
    NSString *bundleID = receipt[@"guestBundleID"];
    NSString *containerUUID = receipt[@"containerUUID"];
    NSString *diskDirectoryName = receipt[@"diskDirectoryName"];
    NSInteger keychainGroup = -1;
    if ([receipt[@"keychainGroup"] isKindOfClass:[NSNumber class]]) {
        keychainGroup = [(NSNumber *)receipt[@"keychainGroup"] integerValue];
    }
    if (bundleID.length == 0 || containerUUID.length == 0) {
        return NO;
    }

    // 重启已确认：先写收据，再加载客 App。
    SBDiagLogLine([[NSString stringWithFormat:@"新进程：收到客启动请求 %@，收据已确认，开始加载客 App", bundleID] UTF8String]);
    [SBGuestLoader markReceiptStage:SBReceiptStageRestartConfirmed detail:nil];

    NSError *error = nil;
    BOOL loaded = [SBGuestBootstrap loadGuestWithBundleID:bundleID
                                            containerUUID:containerUUID
                                        diskDirectoryName:diskDirectoryName
                                            keychainGroup:keychainGroup
                                                    error:&error];
    if (loaded) {
        // 客 App 的 main 已跑过并返回，回到桌面：清掉全部启动标记。
        [SBGuestLoader clearLaunchRequest];
        return YES;
    }

    // 加载失败：收据写成 guest-failed（带中文原因），selection 清掉，
    // 宿主进桌面后按收据弹错；lastLaunchResult 由 Swift 侧（SBStore）按收据记录。
    NSString *message = error.localizedDescription;
    if (message.length == 0) {
        message = @"客 App 加载失败";
    }
    NSString *guestAppPath = [SBGuestLoader guestAppPathForBundleID:bundleID
                                                  diskDirectoryName:diskDirectoryName];
    SBDiagLogLine([[NSString stringWithFormat:@"客加载失败：[code=%ld] %@ %@ %@", (long)(error ? error.code : SBGuestLoaderErrorGuestLoadFailed), bundleID, guestAppPath, message] UTF8String]);
    [SBGuestLoader markReceiptStage:SBReceiptStageGuestFailed detail:message];
    NSUserDefaults *defaults = [SBGuestLoader sharedDefaults];
    [defaults removeObjectForKey:SBKeySelectedGuestBundleID];
    [defaults removeObjectForKey:SBKeySelectedGuestContainer];
    [defaults synchronize];
    return NO;
}

#pragma mark - JIT 检测

+ (BOOL)isJITEnabled {
    // 越狱设备：systemhook 可读即视为有 JIT。
    if (access("/usr/lib/systemhook.dylib", R_OK) == 0) {
        return YES;
    }
    // csops 不在公开头文件里，用 dlsym 取；CS_OPS_STATUS=0，CS_DEBUGGED=0x10000000。
    typedef int (*SBCSOpsFunc)(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
    static SBCSOpsFunc csopsFunc = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        csopsFunc = (SBCSOpsFunc)dlsym(RTLD_DEFAULT, "csops");
    });
    if (!csopsFunc) {
        return NO;
    }
    unsigned int flags = 0;
    if (csopsFunc(getpid(), 0 /* CS_OPS_STATUS */, &flags, sizeof(flags)) != 0) {
        return NO;
    }
    return (flags & 0x10000000 /* CS_DEBUGGED */) != 0;
}

#pragma mark - 启动链自测（F1）

+ (BOOL)runSelfTestWithCertificate:(NSData *)p12
                          password:(NSString *)pass
                             error:(NSError **)error {
    if (p12.length == 0 || pass.length == 0) {
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorSelfTestFailed,
                                            @"自测",
                                            @"自测缺少证书或密码",
                                            @"请先导入证书");
        }
        return NO;
    }

    // ① 收据读写自检：写一条测试收据、读回核对、再恢复原收据。
    NSUserDefaults *defaults = [self sharedDefaults];
    NSData *previousReceipt = [defaults objectForKey:SBKeyLaunchReceipt];
    NSString *testRequestID = [[NSUUID UUID] UUIDString];
    [self writeReceiptWithBundleID:@"__SB_SELFTEST__"
                     containerUUID:@"__SB_SELFTEST__"
                 diskDirectoryName:nil
                     keychainGroup:-1
                             stage:SBReceiptStageRestartRequested
                         requestID:testRequestID
                            detail:nil];
    NSDictionary *readBack = [self currentLaunchReceipt];
    BOOL receiptOK = [readBack[@"requestID"] isEqualToString:testRequestID] &&
                     [readBack[@"guestBundleID"] isEqualToString:@"__SB_SELFTEST__"];
    if (previousReceipt) {
        [defaults setObject:previousReceipt forKey:SBKeyLaunchReceipt];
    } else {
        [defaults removeObjectForKey:SBKeyLaunchReceipt];
    }
    [defaults synchronize];
    if (!receiptOK) {
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorSelfTestFailed,
                                            @"自测",
                                            @"重启收据自检失败：写入后读回不一致",
                                            @"请重试自测");
        }
        return NO;
    }

    // ② 找自测件 SBGuestHooks.dylib：先在宿主包内找，再到 Documents/Tweaks 下找。
    NSString *hooksPath = [[NSBundle mainBundle] pathForResource:@"SBGuestHooks" ofType:@"dylib"];
    if (hooksPath.length == 0) {
        NSString *tweaksPath = [[[self documentsDirectory] stringByAppendingPathComponent:@"Tweaks"]
                                stringByAppendingPathComponent:@"SBGuestHooks.dylib"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:tweaksPath]) {
            hooksPath = tweaksPath;
        }
    }
    if (hooksPath.length == 0) {
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorSelfTestFailed,
                                            @"自测",
                                            @"自测件缺失：SBGuestHooks.dylib 未随应用打包",
                                            @"请重新安装宿主应用");
        }
        return NO;
    }

    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"SBGuestHooks-selftest.dylib"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager removeItemAtPath:tmpPath error:nil];
    NSError *copyError = nil;
    if (![fileManager copyItemAtPath:hooksPath toPath:tmpPath error:&copyError]) {
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorSelfTestFailed,
                                            @"自测",
                                            [NSString stringWithFormat:@"自测件复制失败：%@", copyError.localizedDescription],
                                            @"请重试自测");
        }
        return NO;
    }

    // ③ 证书校验：status 为 0 才算有效。status 语义已按 ZSign/zsign.mm 源码确认：
    // status 是 OCSP 响应里的证书状态（0 = GOOD 未吊销，1 = REVOKED，2 = UNKNOWN；
    // 口令错、非 Apple 颁发者、无 OCSP、联网失败全部以 status 2 回），不是假设；
    // 过期与否 checkCert 本身不判，只回 X509 notAfter 解析出的过期日。
    __block int certStatus = -1;
    __block NSString *certErrorString = nil;
    dispatch_semaphore_t certSema = dispatch_semaphore_create(0);
    [ZSigner checkCert:p12 pass:pass completionHandler:^(int status, NSDate *expirationDate, NSString *organizationalUnitName, NSString *errorString) {
        certStatus = status;
        certErrorString = errorString;
        dispatch_semaphore_signal(certSema);
    }];
    if (dispatch_semaphore_wait(certSema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC))) != 0) {
        [fileManager removeItemAtPath:tmpPath error:nil];
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorSelfTestFailed,
                                            @"证书检查",
                                            @"证书校验超时，请重试",
                                            @"请重试自测");
        }
        return NO;
    }
    if (certStatus != 0) {
        [fileManager removeItemAtPath:tmpPath error:nil];
        if (error) {
            NSString *message = certErrorString.length > 0
                ? [NSString stringWithFormat:@"证书无效：%@", certErrorString]
                : @"证书无效，请重新导入证书";
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorSelfTestFailed,
                                            @"证书检查",
                                            message,
                                            @"请重新导入证书");
        }
        return NO;
    }

    // ④ 用证书签测试件，再静态校验签名能被系统认可（0.2.2 前是 dlopen，见 ⑤）。
    __block BOOL signSuccess = NO;
    __block NSError *signError = nil;
    dispatch_semaphore_t signSema = dispatch_semaphore_create(0);
    [ZSigner signMachOPathArr:@[ tmpPath ]
                     bundleId:@"com.mjorb.sealbox.selftest"
                         cert:p12
                         pass:pass
            completionHandler:^(BOOL success, NSError *signCallbackError) {
        signSuccess = success;
        signError = signCallbackError;
        dispatch_semaphore_signal(signSema);
    }];
    if (dispatch_semaphore_wait(signSema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC))) != 0) {
        [fileManager removeItemAtPath:tmpPath error:nil];
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorSelfTestFailed,
                                            @"自测",
                                            @"证书链自测失败：签名测试件超时",
                                            @"请重试自测");
        }
        return NO;
    }
    if (!signSuccess) {
        [fileManager removeItemAtPath:tmpPath error:nil];
        if (error) {
            NSString *message = signError.localizedDescription.length > 0
                ? [NSString stringWithFormat:@"证书链自测失败：签名测试件失败（%@）", signError.localizedDescription]
                : @"证书链自测失败：签名测试件失败";
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorSelfTestFailed,
                                            @"自测",
                                            message,
                                            @"请检查证书后重试");
        }
        return NO;
    }

    // ⑤ 静态校验签名，不再 dlopen。
    // 0.2.2 改：0.2.1 自测在这里 dlopen(tmpPath)，MJ 的 0.2.1 报
    // code signature invalid——不是签名坏了（blob 存在、签名步骤已成功），
    // 而是 dyld 要求进程内 dlopen 的 dylib 与宿主进程同 Team：测试件用导入
    // 证书签（Team Wan），宿主进程是 CI 自签（无 Team），Team 不一致就被拒。
    // dlopen 测的是“宿主进程能不能加载它”，而真正决定客 App 能不能打开的
    // 是“客主程序与注入件同不同 Team”——那是自测第 ⑥ 步（Swift 侧，
    // SBCertificate.ensureHooksDylibSigned）校验的。所以这里改成静态校验
    // SBCodesignCheck：手动解析 CodeDirectory，验证结构完整、每页哈希一致、
    // CMS 签名块存在，不把测试件加载进宿主进程；自测仍在，仍会红，不是删自测
    // 掩盖问题。校验本身不用 SecStaticCode*：那是 macOS-only API，iOS SDK
    // 里没有（0.2.2 第一轮 CI 实证：Swift 侧报 cannot find in scope）。
    // 边界：不做 CMS 密码学验链，那是 dyld 加载时做的事。
    NSError *validationError = nil;
    if (![SBCodesignCheck validateSignatureAtPath:tmpPath error:&validationError]) {
        [fileManager removeItemAtPath:tmpPath error:nil];
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorSelfTestFailed,
                                            @"自测",
                                            [NSString stringWithFormat:@"证书链自测失败：%@", validationError.localizedDescription],
                                            @"请检查证书后重试");
        }
        return NO;
    }
    [fileManager removeItemAtPath:tmpPath error:nil];
    return YES;
}

@end
