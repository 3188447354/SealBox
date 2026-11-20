// SBSecItemHook.m — 钥匙串 Hook：SecItem* 调用改写 kSecAttrAccessGroup
// 为该容器的 keychain group（com.mjorb.sealbox.shared[.N]，见契约 keychainGroupCount=128）。
// 做法：先用 dlsym 记下原函数，再用 litehook_rebind_symbol 把客可执行镜像里
// 对 SecItem* 的调用重定向到替身；替身改写 access group 后调原函数。
// 局限：只改写客镜像自己的调用；系统框架替客 App 调的 SecItem 不经过这里。
// 0.2.25：litehook_rebind_symbol 的 replacee 参数是原函数指针（头文件签名
// void litehook_rebind_symbol(const mach_header_u *, void *replacee, void *,
// bool (*)(const mach_header_u *))；LC 的 SecItem.m:145-151 传 SecItemAdd 本体）。
// 0.2.24 之前传的是 "_SecItemAdd" 字符串字面量——litehook 按 replacee 的地址
// 比 GOT 表项，字符串地址永远比不上真实函数地址，4 处重绑全是静默 no-op，
// 钥匙串隔离根本没装上；本版改传 dlsym 到的 g_orig_* 指针。
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>

#import "SBGuestHookUtils.h"
#import "litehook.h"

static OSStatus (*g_orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*g_orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*g_orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef) = NULL;
static OSStatus (*g_orig_SecItemDelete)(CFDictionaryRef) = NULL;
// 0.2.26 G3：LC 同款——钥匙串建钥的三处也要改组，否则建出来的钥匙落在
// 宿主默认组里，客下次找不到（还泄漏到宿主组）。
static SecKeyRef (*g_orig_SecKeyCreateRandomKey)(CFDictionaryRef, CFErrorRef *) = NULL;
static SecKeyRef (*g_orig_SecKeyCreateWithData)(CFDataRef, CFDictionaryRef, CFErrorRef *) = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus (*g_orig_SecKeyGeneratePair)(CFDictionaryRef, SecKeyRef *, SecKeyRef *) = NULL;
#pragma clang diagnostic pop

/// 客容器 UUID（SB_GUEST_CONTAINER_PATH 最后一段），供 SecItemAdd 的 alis 用
///（LC 同款：LCUI 按容器删钥匙串时靠它定位）。
static NSString *SBGuestContainerID(void) {
    const char *container = getenv("SB_GUEST_CONTAINER_PATH");
    if (!container || container[0] == '\0') {
        return @"";
    }
    return [[NSString stringWithUTF8String:container] lastPathComponent];
}

/// 复制一份字典并把 kSecAttrAccessGroup 写成客容器组名。original 为 NULL 时返回 NULL。
/// 返回的字典调用方负责 CFRelease；*outCopied 置 YES 表示返回的是新复制的字典。
static CFDictionaryRef SBSecItemRewrittenAttributes(CFDictionaryRef original, BOOL *outCopied) {
    if (outCopied) {
        *outCopied = NO;
    }
    if (!original) {
        return NULL;
    }
    CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, original);
    if (!copy) {
        return original;
    }
    NSString *group = SBGuestKeychainGroupName();
    CFDictionarySetValue(copy, kSecAttrAccessGroup, (__bridge CFStringRef)group);
    if (outCopied) {
        *outCopied = YES;
    }
    return copy;
}

static OSStatus SBHooked_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!g_orig_SecItemAdd) {
        return errSecParam;
    }
    BOOL copied = NO;
    CFDictionaryRef rewritten = SBSecItemRewrittenAttributes(attributes, &copied);
    // 0.2.26 G3：LC 同款——写 alis=容器 UUID，供按容器删钥匙串时定位。
    if (copied) {
        CFDictionarySetValue((CFMutableDictionaryRef)rewritten, @"alis",
                             (__bridge CFStringRef)SBGuestContainerID());
    }
    OSStatus status = g_orig_SecItemAdd(rewritten, result);
    if (copied) {
        CFRelease(rewritten);
    }
    // 0.2.26 G3：LC 同款——errSecParam 时回退原调用（不带 accessGroup 重试），
    // 某些查询不支持 kSecAttrAccessGroup。
    if (status == errSecParam) {
        return g_orig_SecItemAdd(attributes, result);
    }
    return status;
}

static OSStatus SBHooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (!g_orig_SecItemCopyMatching) {
        return errSecParam;
    }
    BOOL copied = NO;
    CFDictionaryRef rewritten = SBSecItemRewrittenAttributes(query, &copied);
    OSStatus status = g_orig_SecItemCopyMatching(rewritten, result);
    if (copied) {
        CFRelease(rewritten);
    }
    if (status == errSecParam) {
        return g_orig_SecItemCopyMatching(query, result);
    }
    return status;
}

static OSStatus SBHooked_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (!g_orig_SecItemUpdate) {
        return errSecParam;
    }
    BOOL queryCopied = NO, attributesCopied = NO;
    CFDictionaryRef rewrittenQuery = SBSecItemRewrittenAttributes(query, &queryCopied);
    CFDictionaryRef rewrittenAttributes = SBSecItemRewrittenAttributes(attributesToUpdate, &attributesCopied);
    OSStatus status = g_orig_SecItemUpdate(rewrittenQuery, rewrittenAttributes);
    if (queryCopied) {
        CFRelease(rewrittenQuery);
    }
    if (attributesCopied) {
        CFRelease(rewrittenAttributes);
    }
    if (status == errSecParam) {
        return g_orig_SecItemUpdate(query, attributesToUpdate);
    }
    return status;
}

static OSStatus SBHooked_SecItemDelete(CFDictionaryRef query) {
    if (!g_orig_SecItemDelete) {
        return errSecParam;
    }
    BOOL copied = NO;
    CFDictionaryRef rewritten = SBSecItemRewrittenAttributes(query, &copied);
    OSStatus status = g_orig_SecItemDelete(rewritten);
    if (copied) {
        CFRelease(rewritten);
    }
    if (status == errSecParam) {
        return g_orig_SecItemDelete(query);
    }
    return status;
}

// 0.2.26 G3：LC 同款 SecKey 建钥 hook——改组；失败时清掉 error 再用原参数重试。
static SecKeyRef SBHooked_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    if (!g_orig_SecKeyCreateRandomKey) {
        return NULL;
    }
    BOOL copied = NO;
    CFDictionaryRef rewritten = SBSecItemRewrittenAttributes(parameters, &copied);
    SecKeyRef key = g_orig_SecKeyCreateRandomKey(rewritten, error);
    if (copied) {
        CFRelease(rewritten);
    }
    if (!key && error && *error) {
        CFRelease(*error);
        *error = NULL;
        key = g_orig_SecKeyCreateRandomKey(parameters, error);
    }
    return key;
}

static SecKeyRef SBHooked_SecKeyCreateWithData(CFDataRef keyData, CFDictionaryRef parameters, CFErrorRef *error) {
    if (!g_orig_SecKeyCreateWithData) {
        return NULL;
    }
    BOOL copied = NO;
    CFDictionaryRef rewritten = SBSecItemRewrittenAttributes(parameters, &copied);
    SecKeyRef key = g_orig_SecKeyCreateWithData(keyData, rewritten, error);
    if (copied) {
        CFRelease(rewritten);
    }
    if (!key && error && *error) {
        CFRelease(*error);
        *error = NULL;
        key = g_orig_SecKeyCreateWithData(keyData, parameters, error);
    }
    return key;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus SBHooked_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    if (!g_orig_SecKeyGeneratePair) {
        return errSecParam;
    }
    BOOL copied = NO;
    CFDictionaryRef rewritten = SBSecItemRewrittenAttributes(parameters, &copied);
    OSStatus status = g_orig_SecKeyGeneratePair(rewritten, publicKey, privateKey);
    if (copied) {
        CFRelease(rewritten);
    }
    if (status == errSecParam) {
        return g_orig_SecKeyGeneratePair(parameters, publicKey, privateKey);
    }
    return status;
}
#pragma clang diagnostic pop

/// 已装过重绑的客可执行路径（按路径去重；多客各装各的镜像）。
static NSMutableSet<NSString *> *SBSecItemInstalledExecPaths(void) {
    static NSMutableSet<NSString *> *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSMutableSet set];
    });
    return set;
}

/// 原函数指针只记一次（各客共用同一份原函数）。
static void SBSecItemHookSetupOriginals(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_orig_SecItemAdd = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))dlsym(RTLD_DEFAULT, "SecItemAdd");
        g_orig_SecItemCopyMatching = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
        g_orig_SecItemUpdate = (OSStatus (*)(CFDictionaryRef, CFDictionaryRef))dlsym(RTLD_DEFAULT, "SecItemUpdate");
        g_orig_SecItemDelete = (OSStatus (*)(CFDictionaryRef))dlsym(RTLD_DEFAULT, "SecItemDelete");
        g_orig_SecKeyCreateRandomKey = (SecKeyRef (*)(CFDictionaryRef, CFErrorRef *))dlsym(RTLD_DEFAULT, "SecKeyCreateRandomKey");
        g_orig_SecKeyCreateWithData = (SecKeyRef (*)(CFDataRef, CFDictionaryRef, CFErrorRef *))dlsym(RTLD_DEFAULT, "SecKeyCreateWithData");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        g_orig_SecKeyGeneratePair = (OSStatus (*)(CFDictionaryRef, SecKeyRef *, SecKeyRef *))dlsym(RTLD_DEFAULT, "SecKeyGeneratePair");
#pragma clang diagnostic pop
    });
}

/// 按客镜像安装（0.2.27）：constructor 只跑首客，第二客起由宿主在 dlopen 后
/// 经 SBGuestHooksInstallForGuest 再调；按执行路径去重，各客镜像各装一套。
/// 探针按当前客组重跑（组不同 entitlement 覆盖可能不同）；探针失败不记已装，下客再试。
void SBSecItemHookInstallForGuestImage(void) {
    const struct mach_header *guestHeader = SBGuestImageHeader();
    if (!guestHeader) {
        NSLog(@"[Sealbox] SecItem Hook 未安装：找不到客可执行镜像");
        return;
    }
    const char *execPath = getenv("SB_GUEST_EXEC_PATH");
    NSString *execPathString = execPath ? [NSString stringWithUTF8String:execPath] : @"";
    NSMutableSet<NSString *> *installed = SBSecItemInstalledExecPaths();
    @synchronized (installed) {
        if ([installed containsObject:execPathString]) {
            return; // 该客镜像已装过
        }
    }
    // 0.2.26 G3：LC 同款探针——先拿假查询问钥匙串组能不能用；宿主缺
    // keychain-access-groups entitlement 时（errSecMissingEntitlement）
    // 不装 hook，否则所有 SecItem 调用都会被改写进一个不可用的组而失败。
    NSDictionary *probeQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: @"NonExistentKey",
        (__bridge id)kSecAttrService: @"NonExistentService",
        (__bridge id)kSecAttrAccessGroup: SBGuestKeychainGroupName(),
        (__bridge id)kSecReturnData: @NO
    };
    OSStatus probeStatus = SecItemCopyMatching((__bridge CFDictionaryRef)probeQuery, NULL);
    if (probeStatus == errSecMissingEntitlement) {
        NSLog(@"[Sealbox] SecItem Hook 未安装：钥匙串组 %@ 不可用（缺 entitlement）", SBGuestKeychainGroupName());
        return;
    }
    // 先记原函数，再重绑定；顺序反了替身会调到自己。
    SBSecItemHookSetupOriginals();
    if (g_orig_SecItemAdd) {
        litehook_rebind_symbol(guestHeader, (void *)g_orig_SecItemAdd, (void *)SBHooked_SecItemAdd, NULL);
    }
    if (g_orig_SecItemCopyMatching) {
        litehook_rebind_symbol(guestHeader, (void *)g_orig_SecItemCopyMatching, (void *)SBHooked_SecItemCopyMatching, NULL);
    }
    if (g_orig_SecItemUpdate) {
        litehook_rebind_symbol(guestHeader, (void *)g_orig_SecItemUpdate, (void *)SBHooked_SecItemUpdate, NULL);
    }
    if (g_orig_SecItemDelete) {
        litehook_rebind_symbol(guestHeader, (void *)g_orig_SecItemDelete, (void *)SBHooked_SecItemDelete, NULL);
    }
    if (g_orig_SecKeyCreateRandomKey) {
        litehook_rebind_symbol(guestHeader, (void *)g_orig_SecKeyCreateRandomKey, (void *)SBHooked_SecKeyCreateRandomKey, NULL);
    }
    if (g_orig_SecKeyCreateWithData) {
        litehook_rebind_symbol(guestHeader, (void *)g_orig_SecKeyCreateWithData, (void *)SBHooked_SecKeyCreateWithData, NULL);
    }
    if (g_orig_SecKeyGeneratePair) {
        litehook_rebind_symbol(guestHeader, (void *)g_orig_SecKeyGeneratePair, (void *)SBHooked_SecKeyGeneratePair, NULL);
    }
    @synchronized (installed) {
        [installed addObject:execPathString];
    }
    NSLog(@"[Sealbox] SecItem Hook 已安装：重绑 SecItemAdd/CopyMatching/Update/Delete + SecKeyCreateRandomKey/CreateWithData/GeneratePair（0.2.25 函数指针传法；0.2.26 补 SecKey* 与探针；0.2.27 按客镜像）");
}

/// 旧入口（兼容）：即 per-guest 安装。
void SBSecItemHookInstall(void) {
    SBSecItemHookInstallForGuestImage();
}
