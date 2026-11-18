//
//  zsigner.h
//  LiveContainer
//
//  Created by s s on 2024/11/10.
//
#import <Foundation/Foundation.h>


@interface ZSigner : NSObject
+ (NSProgress*)signWithAppPath:(NSString *)appPath bundleId:(NSString *)bundleId cert:(NSData *)key pass:(NSString *)pass completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
+ (BOOL)adhocSignMachOAtPath:(NSString *)path bundleId:(NSString*)bundleId entitlementData:(NSData *)entitlementData;
+ (NSProgress*)signMachOPathArr:(NSArray<NSString*>*)machoPathArr bundleId:(NSString *)bundleId cert:(NSData *)key
                           pass:(NSString *)pass completionHandler:(void(^)(BOOL success, NSError *error))completionHandler;
// 0.2.5：带 entitlements 的变体。entitlementXML 非 nil 时，ZSignAsset 置
// m_bForceEntitlements 并把 XML 写进 m_strEntitleData——打过补丁的客主程序
// 是 MH_DYLIB，原来的 IsExecute() 门会把 entitlements 写空，靠这个绕过去。
// 调用方一次只签一个可执行文件（主程序或某个 appex），各用自己的 entitlements。
// entitlementXML 为 nil 时与旧方法完全一致（不置位、不写 entitlements）。
+ (NSProgress*)signMachOPathArr:(NSArray<NSString*>*)machoPathArr bundleId:(NSString *)bundleId cert:(NSData *)key
                           pass:(NSString *)pass entitlementXML:(nullable NSString *)entitlementXML
             completionHandler:(void(^)(BOOL success, NSError *error))completionHandler;
// this method is used to get teamId for ADP/Enterprise certs ,don't use it in normal jitless
+ (NSString*)getTeamIdWithCert:(NSData *)cert pass:(NSString *)pass;
+ (int)checkCert:(NSData *)cert pass:(NSString *)pass completionHandler:(void(^)(int status, NSDate* expirationDate, NSString* organizationalUnitName, NSString *error))completionHandler;
@end
