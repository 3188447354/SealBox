//
//  SBSigner.mm
//  Sealbox
//
//  STUB：脚手架先行版。完整实现由 Installer 模块替换。
//

#import "SBSigner.h"

@implementation SBSigner

+ (void)signAppAtPath:(NSString *)appPath
             bundleID:(NSString *)bundleID
                 cert:(NSData *)certData
             password:(NSString *)password
           completion:(void (^)(BOOL success, NSError *_Nullable error))completion {
    if (completion) {
        NSError *error = [NSError errorWithDomain:@"SBSigner"
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"签名器尚未实现"}];
        completion(NO, error);
    }
}

+ (void)checkCertificate:(NSData *)certData
                password:(NSString *)password
              completion:(void (^)(NSInteger status, NSDate *_Nullable expirationDate, NSString *_Nullable organizationalUnitName, NSString *_Nullable error))completion {
    if (completion) {
        completion(-1, nil, nil, @"签名器尚未实现");
    }
}

@end
