//
//  SBGuestLoader.m
//  Sealbox
//
//  STUB：脚手架先行版。完整实现由 GuestLoader 模块替换。
//

#import "SBGuestLoader.h"

@implementation SBGuestLoader

+ (instancetype)shared {
    static SBGuestLoader *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SBGuestLoader alloc] init];
    });
    return instance;
}

+ (BOOL)isGuestLaunchRequested {
    // STUB：脚手架阶段永不进客 App。
    return NO;
}

- (void)requestGuestLaunchWithBundleID:(NSString *)bundleID
                        containerUUID:(NSString *)containerUUID
                           completion:(void (^)(NSError *_Nullable error))completion {
    if (completion) {
        NSError *error = [NSError errorWithDomain:@"SBGuestLoader"
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"客加载器尚未实现"}];
        completion(error);
    }
}

- (BOOL)launchGuestIfRequested {
    return NO;
}

+ (BOOL)isJITEnabled {
    return NO;
}

+ (BOOL)runSelfTestWithCertificate:(NSData *)p12
                          password:(NSString *)pass
                             error:(NSError **)error {
    if (error) {
        *error = [NSError errorWithDomain:@"SBGuestLoader"
                                     code:-1
                                 userInfo:@{NSLocalizedDescriptionKey: @"自测尚未实现"}];
    }
    return NO;
}

@end
