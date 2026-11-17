// SBGuestHookUtils.h — 客端 Hook 共用的小辅助：找客可执行镜像头、读钥匙串组名。
// 只用公开头文件；本文件只被 GuestHooks target 里的 .m 包含。
#ifndef SBGuestHookUtils_h
#define SBGuestHookUtils_h

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <stdlib.h>
#import <string.h>

/// 客可执行文件在当前进程里的 mach_header：按环境变量 SB_GUEST_EXEC_PATH
///（宿主 SBGuestBootstrap 在 dlopen 前写好）找；找不到时按文件名兜底。
static inline const struct mach_header *SBGuestImageHeader(void) {
    const char *execPath = getenv("SB_GUEST_EXEC_PATH");
    if (!execPath) {
        return NULL;
    }
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strcmp(name, execPath) == 0) {
            return _dyld_get_image_header(i);
        }
    }
    NSString *execName = [[NSString stringWithUTF8String:execPath] lastPathComponent];
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && [[[NSString stringWithUTF8String:name] lastPathComponent] isEqualToString:execName]) {
            return _dyld_get_image_header(i);
        }
    }
    return NULL;
}

/// 该客容器用的钥匙串组名：环境变量 SB_GUEST_KEYCHAIN_GROUP（宿主写好），
/// 格式 com.mjorb.sealbox.shared[.N]；没有则退回组 0。
static inline NSString *SBGuestKeychainGroupName(void) {
    const char *group = getenv("SB_GUEST_KEYCHAIN_GROUP");
    if (group && group[0] != '\0') {
        return [NSString stringWithUTF8String:group];
    }
    return @"com.mjorb.sealbox.shared";
}

#endif /* SBGuestHookUtils_h */
