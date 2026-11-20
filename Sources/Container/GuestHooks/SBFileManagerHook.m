// SBFileManagerHook.m — 文件管理 Hook：容器路径改写。
//   ① -[NSFileManager containerURLForSecurityApplicationGroupIdentifier:]
//      按组返回客容器下的 LCAppGroup/<组>（LC 的隔离式布局）；宿主自己的
//      App Group 走原实现；
//   ② 客镜像里对 NSHomeDirectory() 的调用重定向到客容器（HOME 环境变量
//      已被宿主改过，这里是给直接调该函数的客代码再兜一层底）。
//   ③ -[NSFileManager createDirectoryAtPath:...]：WebKit 建 Library/Cookies
//      时的特殊处理（LC 的 issue #888 修法，见实现内注释）。
// 0.2.25：litehook_rebind_symbol 的 replacee 参数是原函数指针，不是符号名
// 字符串（见 SBSecItemHook.m 文件头同款说明）——0.2.24 之前传 "_NSHomeDirectory"
// 字符串是静默 no-op；本版改传 dlsym 到的 g_orig_NSHomeDirectory。
// 其余目录（Documents/Caches 等）靠宿主改写 HOME 自然落进客容器，不另 Hook。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

#import "SBGuestHookUtils.h"
#import "litehook.h"

@interface NSFileManager (SBGuestHook)
- (nullable NSURL *)sb_guest_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier;
- (BOOL)sb_guest_createDirectoryAtPath:(NSString *)path
           withIntermediateDirectories:(BOOL)createIntermediates
                            attributes:(nullable NSDictionary<NSFileAttributeKey, id> *)attributes
                                 error:(NSError **)error;
@end

/// WebKit 镜像基址（G4b 的调用方判定用）：已加载则直接找，没加载则 dlopen
/// 再找；找不到时为 NULL，Cookies hook 不介入（LC 用 DSC 符号缓存，我们
/// 不用 DSC machinery，只读一次、现找）。
static void *g_sbWebKitHeader = NULL;

static void *SBWebKitImageHeader(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/WebKit.framework/WebKit") != NULL) {
            return (void *)_dyld_get_image_header(i);
        }
    }
    dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_GLOBAL);
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/WebKit.framework/WebKit") != NULL) {
            return (void *)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

@implementation NSFileManager (SBGuestHook)

- (nullable NSURL *)sb_guest_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    // 0.2.26 G4a：LC 同款（NSFileManager+GuestHooks.m）——
    // ① 宿主自己的 App Group 走原实现；
    // ② 其余组按 LC 的隔离式布局返回客容器下的 LCAppGroup/<组>，并建
    //    Library/Caches。以前所有组都返回容器根，客用两个组时会撞目录。
    if ([groupIdentifier hasPrefix:@"group.com.mjorb.sealbox"]) {
        return [self sb_guest_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
    }
    const char *container = getenv("SB_GUEST_CONTAINER_PATH");
    if (container && container[0] != '\0') {
        NSString *groupPath = [[NSString stringWithUTF8String:container]
            stringByAppendingPathComponent:[@"LCAppGroup" stringByAppendingPathComponent:groupIdentifier]];
        [[NSFileManager defaultManager] createDirectoryAtPath:[groupPath stringByAppendingPathComponent:@"Library/Caches"]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        return [NSURL fileURLWithPath:groupPath];
    }
    // 交换后调到这里就是原实现。
    return [self sb_guest_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
}

- (BOOL)sb_guest_createDirectoryAtPath:(NSString *)path
           withIntermediateDirectories:(BOOL)createIntermediates
                            attributes:(nullable NSDictionary<NSFileAttributeKey, id> *)attributes
                                 error:(NSError **)error {
    BOOL ans = [self sb_guest_createDirectoryAtPath:path
                        withIntermediateDirectories:createIntermediates
                                         attributes:attributes
                                              error:error];
    // 0.2.26 G4b：LC 同款 WebKit Cookies 修法（LiveContainer issue #888）。
    // 沙盒容器路径是定的（宿主容器），HOME 环境变量改不走它——WebKit 算出
    // 的 cookie 目录仍是宿主的 Library/Cookies；若 createDirectoryAtPath
    // 对它返回 NO（它是软链），WebKit 拿不到 cookie 目录的 sandbox
    // bookmark，Networking 进程就写不了 cookie。所以这里把宿主的 Cookies
    // 移到 Cookies2、再把宿主的 Cookies 软链到客的 Library/Cookies，
    // 返回 YES。进宿主界面时 main.m 把 Cookies2 移回来（LC 同款）。
    // 只在调用方落在 WebKit 前 32MB 内、且路径以 Library/Cookies 结尾时介入。
    void *callerAddr = __builtin_return_address(0);
    if (g_sbWebKitHeader && callerAddr > g_sbWebKitHeader &&
        callerAddr < (g_sbWebKitHeader + (32 << 20))) {
        if ([path hasSuffix:@"Library/Cookies"]) {
            const char *hostHome = getenv("SB_HOST_HOME");
            const char *guestHome = getenv("SB_GUEST_CONTAINER_PATH");
            if (hostHome && hostHome[0] != '\0' && guestHome && guestHome[0] != '\0') {
                NSFileManager *fm = [NSFileManager defaultManager];
                NSString *hostLibrary = [[NSString stringWithUTF8String:hostHome]
                    stringByAppendingPathComponent:@"Library"];
                NSString *cookies2Path = [hostLibrary stringByAppendingPathComponent:@"Cookies2"];
                NSString *cookiesPath = [hostLibrary stringByAppendingPathComponent:@"Cookies"];
                NSString *guestCookiesPath = [[NSString stringWithUTF8String:guestHome]
                    stringByAppendingPathComponent:@"Library/Cookies"];
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:cookies2Path isDirectory:&isDir]) {
                    if ([fm fileExistsAtPath:cookiesPath isDirectory:&isDir]) {
                        [fm moveItemAtPath:cookiesPath toPath:cookies2Path error:nil];
                    } else {
                        [fm createDirectoryAtPath:cookies2Path withIntermediateDirectories:YES attributes:nil error:nil];
                    }
                }
                remove([cookiesPath UTF8String]);
                symlink([guestCookiesPath UTF8String], [cookiesPath UTF8String]);
                return YES;
            }
        }
    }
    return ans;
}

@end

static NSString *(*g_orig_NSHomeDirectory)(void) = NULL;

static NSString *SBHookedNSHomeDirectory(void) {
    const char *container = getenv("SB_GUEST_CONTAINER_PATH");
    if (container && container[0] != '\0') {
        return [NSString stringWithUTF8String:container];
    }
    if (g_orig_NSHomeDirectory) {
        return g_orig_NSHomeDirectory();
    }
    return nil;
}

/// 已装过 NSHomeDirectory 重绑的客可执行路径（按路径去重）。
static NSMutableSet<NSString *> *SBFileManagerInstalledExecPaths(void) {
    static NSMutableSet<NSString *> *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSMutableSet set];
    });
    return set;
}

/// 按客镜像安装（0.2.27）：方法交换（containerURL / createDirectory）是
/// 进程全局的、只装一次（替身按调用取环境变量，已是动态的）；NSHomeDirectory
/// 重绑在客镜像上，各客镜像各装一套（按执行路径去重）。
void SBFileManagerHookInstallForGuestImage(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 0.2.26 G4b：WebKit 镜像基址现找一次（见文件头），供 Cookies hook
        // 判定调用方；找不到时为 NULL，hook 仍装、只不介入。
        g_sbWebKitHeader = SBWebKitImageHeader();
        Method orig = class_getInstanceMethod([NSFileManager class],
                                              @selector(containerURLForSecurityApplicationGroupIdentifier:));
        Method repl = class_getInstanceMethod([NSFileManager class],
                                              @selector(sb_guest_containerURLForSecurityApplicationGroupIdentifier:));
        if (orig && repl) {
            method_exchangeImplementations(orig, repl);
        }
        // 0.2.26 G4b：createDirectoryAtPath 也 swizzle（WebKit Cookies 修法）。
        Method origCreateDir = class_getInstanceMethod([NSFileManager class],
                                                       @selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:));
        Method replCreateDir = class_getInstanceMethod([NSFileManager class],
                                                       @selector(sb_guest_createDirectoryAtPath:withIntermediateDirectories:attributes:error:));
        if (origCreateDir && replCreateDir) {
            method_exchangeImplementations(origCreateDir, replCreateDir);
        }
    });
    const struct mach_header *guestHeader = SBGuestImageHeader();
    if (!guestHeader) {
        NSLog(@"[Sealbox] NSHomeDirectory Hook 未安装：找不到客可执行镜像");
        return;
    }
    const char *execPath = getenv("SB_GUEST_EXEC_PATH");
    NSString *execPathString = execPath ? [NSString stringWithUTF8String:execPath] : @"";
    NSMutableSet<NSString *> *installed = SBFileManagerInstalledExecPaths();
    @synchronized (installed) {
        if ([installed containsObject:execPathString]) {
            return; // 该客镜像已装过
        }
        [installed addObject:execPathString];
    }
    if (!g_orig_NSHomeDirectory) {
        g_orig_NSHomeDirectory = (NSString *(*)(void))dlsym(RTLD_DEFAULT, "NSHomeDirectory");
    }
    if (g_orig_NSHomeDirectory) {
        litehook_rebind_symbol(guestHeader, (void *)g_orig_NSHomeDirectory, (void *)SBHookedNSHomeDirectory, NULL);
        NSLog(@"[Sealbox] NSHomeDirectory Hook 已安装（0.2.25 函数指针传法；0.2.27 按客镜像）");
    }
    NSLog(@"[Sealbox] FileManager Hook 已安装：containerURLForSecurityApplicationGroupIdentifier（0.2.26 按组分子目录）＋ createDirectoryAtPath（WebKit Cookies 修法）");
}

/// 旧入口（兼容）：即 per-guest 安装。
void SBFileManagerHookInstall(void) {
    SBFileManagerHookInstallForGuestImage();
}
