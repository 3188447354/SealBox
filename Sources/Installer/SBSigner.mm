// SBSigner.mm — SBSigner 的实现：把调用原样转发给 ZSign，不加自己的签名逻辑。

#import "SBSigner.h"
#import "zsigner.h"

@implementation SBSigner

+ (void)signAppAtPath:(NSString *)appPath
             bundleID:(NSString *)bundleID
             certData:(NSData *)certData
             password:(NSString *)password
             progress:(nullable NSProgress *)progress
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    // progress 仅作调用方展示用；ZSign 返回自己的 NSProgress，本包装不做二次转发。
    (void)progress;
    [ZSigner signWithAppPath:appPath
                    bundleId:bundleID
                        cert:certData
                        pass:password
           completionHandler:^(BOOL success, NSError *error) {
               completion(success, error);
           }];
}

+ (void)checkCertificateWithData:(NSData *)certData
                        password:(NSString *)password
                      completion:(void (^)(NSInteger status,
                                          NSDate * _Nullable expirationDate,
                                          NSString * _Nullable organizationalUnitName,
                                          NSString * _Nullable errorMessage))completion {
    [ZSigner checkCert:certData
                  pass:password
     completionHandler:^(int status, NSDate *expirationDate, NSString *organizationalUnitName, NSString *error) {
         completion((NSInteger)status, expirationDate, organizationalUnitName, error);
     }];
}

+ (BOOL)adhocSignMachOAtPath:(NSString *)path
                    bundleID:(NSString *)bundleID
             entitlementData:(nullable NSData *)entitlementData {
    return [ZSigner adhocSignMachOAtPath:path bundleId:bundleID entitlementData:entitlementData];
}

@end
