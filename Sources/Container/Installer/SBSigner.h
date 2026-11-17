// SBSigner.h — SBSigner：ZSign 签名库的 ObjC++ 薄包装，供 Swift 安装管线调用。
//
// 本文件只做转发，不含任何自己的签名逻辑：签 App、验证书、adhoc 签 Mach-O
// 全部交给 ZSign（ZSign/zsigner.h）。Swift 侧按模块契约调这三个方法。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SBSigner : NSObject

/// 对整个 .app 重签（转发 `ZSigner signWithAppPath`）。
/// - Parameters:
///   - appPath: .app 在磁盘上的完整路径。
///   - bundleID: 客 App 的 Bundle ID。
///   - certData: p12 证书数据（NSData 传入，不走文件路径）。
///   - password: p12 密码。
///   - progress: 调用方传入的进度对象，仅作展示用；ZSign 内部另有自己的 NSProgress。
///   - completion: 完成回调；成功时 error 为 nil。
+ (void)signAppAtPath:(NSString *)appPath
             bundleID:(NSString *)bundleID
             certData:(NSData *)certData
             password:(NSString *)password
             progress:(nullable NSProgress *)progress
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

/// 校验 p12 证书（转发 `ZSigner checkCert`）。
/// - Parameters:
///   - certData: p12 证书数据。
///   - password: p12 密码。
///   - completion: 回调 status（ZSign 返回的原始状态码）、过期日、组织单位名、
///     错误描述字符串（无错时为 nil）。
+ (void)checkCertificateWithData:(NSData *)certData
                        password:(NSString *)password
                      completion:(void (^)(NSInteger status,
                                          NSDate * _Nullable expirationDate,
                                          NSString * _Nullable organizationalUnitName,
                                          NSString * _Nullable errorMessage))completion;

/// 对单个 Mach-O 做 adhoc 签名（转发 `ZSigner adhocSignMachOAtPath`）。
/// - Parameters:
///   - path: Mach-O 文件路径。
///   - bundleID: 客 App 的 Bundle ID。
///   - entitlementData: entitlement 数据，可为 nil。
/// - Returns: 成功返回 YES。
+ (BOOL)adhocSignMachOAtPath:(NSString *)path
                    bundleID:(NSString *)bundleID
             entitlementData:(nullable NSData *)entitlementData;

@end

NS_ASSUME_NONNULL_END
