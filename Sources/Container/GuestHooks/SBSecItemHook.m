// SBSecItemHook.m — 钥匙串 Hook：SecItem* 调用改写 kSecAttrAccessGroup
// 为该容器的 keychain group（com.mjorb.sealbox.shared[.N]，见契约 keychainGroupCount=128）。
// 做法：先用 dlsym 记下原函数，再用 litehook_rebind_symbol 把客可执行镜像里
// 对 SecItem* 的调用重定向到替身；替身改写 access group 后调原函数。
// 局限：只改写客镜像自己的调用；系统框架替客 App 调的 SecItem 不经过这里。
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>

#import "SBGuestHookUtils.h"
#import "litehook.h"

static OSStatus (*g_orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*g_orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*g_orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef) = NULL;
static OSStatus (*g_orig_SecItemDelete)(CFDictionaryRef) = NULL;

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
    OSStatus status = g_orig_SecItemAdd(rewritten, result);
    if (copied) {
        CFRelease(rewritten);
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
    return status;
}

void SBSecItemHookInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const struct mach_header *guestHeader = SBGuestImageHeader();
        if (!guestHeader) {
            NSLog(@"[Sealbox] SecItem Hook 未安装：找不到客可执行镜像");
            return;
        }
        // 先记原函数，再重绑定；顺序反了替身会调到自己。
        g_orig_SecItemAdd = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))dlsym(RTLD_DEFAULT, "SecItemAdd");
        g_orig_SecItemCopyMatching = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
        g_orig_SecItemUpdate = (OSStatus (*)(CFDictionaryRef, CFDictionaryRef))dlsym(RTLD_DEFAULT, "SecItemUpdate");
        g_orig_SecItemDelete = (OSStatus (*)(CFDictionaryRef))dlsym(RTLD_DEFAULT, "SecItemDelete");
        if (g_orig_SecItemAdd) {
            litehook_rebind_symbol(guestHeader, "_SecItemAdd", (void *)SBHooked_SecItemAdd, NULL);
        }
        if (g_orig_SecItemCopyMatching) {
            litehook_rebind_symbol(guestHeader, "_SecItemCopyMatching", (void *)SBHooked_SecItemCopyMatching, NULL);
        }
        if (g_orig_SecItemUpdate) {
            litehook_rebind_symbol(guestHeader, "_SecItemUpdate", (void *)SBHooked_SecItemUpdate, NULL);
        }
        if (g_orig_SecItemDelete) {
            litehook_rebind_symbol(guestHeader, "_SecItemDelete", (void *)SBHooked_SecItemDelete, NULL);
        }
    });
}
