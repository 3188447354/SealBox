// SBUserDefaultsHook.m — UserDefaults 按客容器重定向。
// 机制有两层：① 宿主已把 HOME 指到客数据容器，标准 defaults 的 plist
// 本来就落在客容器里；② 这里再把 +standardUserDefaults 与 -init 换成
// 以客 Bundle ID 为 suite 的实例，让客 App 的偏好设置与宿主彻底分家。
// 注意安装顺序：先建好客实例（initWithSuiteName 不走 -init 交换），再交换方法，
// 避免建实例时重入 dispatch_once。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>

NSUserDefaults *SBGuestDefaults(void);

@interface NSUserDefaults (SBGuestHook)
+ (NSUserDefaults *)sb_guest_standardUserDefaults;
- (instancetype)sb_guest_init;
@end

@implementation NSUserDefaults (SBGuestHook)

+ (NSUserDefaults *)sb_guest_standardUserDefaults {
    // 交换后调到这里；返回下面 SBGuestDefaults() 建好的客实例。
    return SBGuestDefaults();
}

- (instancetype)sb_guest_init {
    // 交换后 [[NSUserDefaults alloc] init] 走到这里：直接返回客实例。
    // 刚 alloc 出来的 self 会被丢弃（一次泄漏，可接受）；initWithSuiteName 不受影响。
    // 0.2.6：init 家族方法按约定返回 +1 引用。旧代码直接返回静态实例
    // （+0），调用方按 +1 释放一次后静态实例被提前销毁，之后再用即
    // use-after-free。这里补一个 CFRetain，把 +1 交给调用方。
    return (NSUserDefaults *)CFRetain((__bridge CFTypeRef)SBGuestDefaults());
}

@end

/// 客偏好实例。0.2.27 多客常驻：按 (suite, HOME) 分键缓存——
// 旧实现 dispatch_once 只建首客的 suite，第二客会读到首客的偏好。
// HOME 是键的一部分：同一 suite 的实例在 HOME 指回该客容器时才复用，
// 否则 initWithSuiteName 解析出的 plist 路径会落在当前（别的客的）容器里。
NSUserDefaults *SBGuestDefaults(void) {
    const char *bundleID = getenv("SB_GUEST_BUNDLE_ID");
    NSString *suite = (bundleID && bundleID[0] != '\0')
        ? [NSString stringWithUTF8String:bundleID]
        : @"com.mjorb.sealbox.guest";
    const char *home = getenv("HOME");
    NSString *key = [NSString stringWithFormat:@"%@|%@",
                     suite, home ? [NSString stringWithUTF8String:home] : @""];
    static NSMutableDictionary<NSString *, NSUserDefaults *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    @synchronized (cache) {
        NSUserDefaults *defaults = cache[key];
        if (!defaults) {
            defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
            cache[key] = defaults;
        }
        return defaults;
    }
}

void SBUserDefaultsHookInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 先建客实例，再交换，避免 initWithSuiteName 内部走到被交换的 -init。
        (void)SBGuestDefaults();
        Method standardOrig = class_getClassMethod([NSUserDefaults class], @selector(standardUserDefaults));
        Method standardRepl = class_getClassMethod([NSUserDefaults class], @selector(sb_guest_standardUserDefaults));
        if (standardOrig && standardRepl) {
            method_exchangeImplementations(standardOrig, standardRepl);
        }
        Method initOrig = class_getInstanceMethod([NSUserDefaults class], @selector(init));
        Method initRepl = class_getInstanceMethod([NSUserDefaults class], @selector(sb_guest_init));
        if (initOrig && initRepl) {
            method_exchangeImplementations(initOrig, initRepl);
        }
    });
}
