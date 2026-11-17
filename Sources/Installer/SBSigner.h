//
//  SBSigner.h
//  Sealbox
//
//  签名器：ZSign 的 ObjC++ 包装（JIT-less 重签用）。
//  STUB：脚手架先行版（只留接口）；完整实现由 Installer 模块替换。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SBSigner : NSObject

/// 用导入的 p12 重签整个客 App 包。
+ (void)signAppAtPath:(NSString *)appPath
             bundleID:(NSString *)bundleID
                 cert:(NSData *)certData
             password:(NSString *)password
           completion:(void (^)(BOOL success, NSError *_Nullable error))completion;

/// 校验 p12 证书：返回状态、过期日、组织单位名。
+ (void)checkCertificate:(NSData *)certData
                password:(NSString *)password
              completion:(void (^)(NSInteger status, NSDate *_Nullable expirationDate, NSString *_Nullable organizationalUnitName, NSString *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
