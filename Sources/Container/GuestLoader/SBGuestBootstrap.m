// SBGuestBootstrap.m — 客 App 启动引导：搭环境、伪装、装 Hook、dlopen 并跳入口。
#import "SBGuestBootstrap.h"

#import <dlfcn.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <unistd.h>

#import "SBGuestEntry.h"
#import "SBGuestLoader.h"
#import "SBBundleSpoof.h"
#import "SBExecPathHook.h"

extern char **environ;

// 钥匙串组名前缀（与契约 SBConstants 一致：com.mjorb.sealbox.shared[.N]）。
static NSString * const SBKeychainGroupPrefix = @"com.mjorb.sealbox.shared";
// 钥匙串组总数（与契约 keychainGroupCount 一致）。
static const NSInteger SBKeychainGroupCount = 128;

@implementation SBGuestBootstrap

+ (NSString *)documentsDirectory {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

/// 容器 UUID 的简单哈希（djb2），只在 Swift 侧没写 SBSelectedGuestKeychainGroup 时
/// 作钥匙串组兜底。见 MODULE_NOTES：该兜底必须与 Store 的分配一致，否则只是“有组可用”。
+ (NSInteger)keychainGroupIndexForContainerUUID:(NSString *)containerUUID {
    const char *bytes = [containerUUID UTF8String];
    if (!bytes) {
        return 0;
    }
    unsigned long hash = 5381;
    for (const unsigned char *p = (const unsigned char *)bytes; *p != '\0'; p++) {
        hash = ((hash << 5) + hash) + *p;
    }
    return (NSInteger)(hash % (unsigned long)SBKeychainGroupCount);
}

+ (BOOL)failWithError:(NSError **)error
                 code:(SBGuestLoaderErrorCode)code
              message:(NSString *)message
             recovery:(NSString *)recovery {
    if (error) {
        *error = SBGuestLoaderErrorMake(code, @"加载客 App", message, recovery);
    }
    return NO;
}

+ (BOOL)loadGuestWithBundleID:(NSString *)bundleID
                containerUUID:(NSString *)containerUUID
            diskDirectoryName:(NSString *)diskDirectoryName
                keychainGroup:(NSInteger)passedKeychainGroup
                        error:(NSError **)error {
    NSString *documents = [self documentsDirectory];
    NSString *dirName = diskDirectoryName.length > 0
        ? diskDirectoryName
        : [bundleID stringByAppendingPathExtension:@"app"];
    NSString *guestAppPath = [[[documents stringByAppendingPathComponent:@"Applications"]
                               stringByAppendingPathComponent:dirName] copy];
    NSString *containerPath = [[[documents stringByAppendingPathComponent:@"Data"]
                                stringByAppendingPathComponent:@"Application"]
                               stringByAppendingPathComponent:containerUUID];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // —— 1. 读客 App 包与 Info.plist ————————————————————————————
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:guestAppPath isDirectory:&isDirectory] || !isDirectory) {
        return [self failWithError:error
                              code:SBGuestLoaderErrorBundleNotFound
                           message:@"找不到客 App 安装包，请重新安装"
                          recovery:@"重新导入该应用"];
    }
    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:
                               [guestAppPath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *executableName = infoPlist[@"CFBundleExecutable"];
    if (executableName.length == 0) {
        // 兜底：用 Bundle ID 最后一段当可执行名。
        executableName = [bundleID componentsSeparatedByString:@"."].lastObject;
    }
    NSString *guestExecPath = [guestAppPath stringByAppendingPathComponent:executableName];
    if (![fileManager fileExistsAtPath:guestExecPath]) {
        return [self failWithError:error
                              code:SBGuestLoaderErrorBundleNotFound
                           message:@"找不到客 App 可执行文件，请重新安装"
                          recovery:@"重新导入该应用"];
    }
    if (is32BitMachOAtPath(guestExecPath)) {
        return [self failWithError:error
                              code:SBGuestLoaderErrorUnsupportedBinary
                           message:@"该应用是 32 位应用，需要 JIT 才能运行"
                          recovery:@"请用 Seal 开启 JIT 后重试，或换用 64 位版本"];
    }
    // 最低系统版本检查（设计 §3.6 新增，0.1.0 未做）：读客 Info.plist 的
    // MinimumOSVersion，与宿主当前系统版本比对；客要求高于宿主时拒绝启动，
    // 文案带两个真实版本号。MinimumOSVersion 缺失或无法解析时不拦
    //（无依据不误拦）。比对按数字分段：16.0 < 16.1 < 17.0，缺段按 0 计。
    NSString *minimumOSVersion = infoPlist[@"MinimumOSVersion"];
    if ([minimumOSVersion isKindOfClass:[NSString class]] && minimumOSVersion.length > 0) {
        NSOperatingSystemVersion hostVersion = [[NSProcessInfo processInfo] operatingSystemVersion];
        NSArray<NSString *> *guestParts = [minimumOSVersion componentsSeparatedByString:@"."];
        NSInteger guestMajor = guestParts.count > 0 ? [guestParts[0] integerValue] : 0;
        NSInteger guestMinor = guestParts.count > 1 ? [guestParts[1] integerValue] : 0;
        NSInteger guestPatch = guestParts.count > 2 ? [guestParts[2] integerValue] : 0;
        BOOL guestRequiresNewer = guestMajor > hostVersion.majorVersion ||
            (guestMajor == hostVersion.majorVersion && guestMinor > hostVersion.minorVersion) ||
            (guestMajor == hostVersion.majorVersion && guestMinor == hostVersion.minorVersion &&
             guestPatch > hostVersion.patchVersion);
        if (guestRequiresNewer) {
            NSString *guestVersionText = guestParts.count > 2
                ? [NSString stringWithFormat:@"%ld.%ld.%ld", (long)guestMajor, (long)guestMinor, (long)guestPatch]
                : [NSString stringWithFormat:@"%ld.%ld", (long)guestMajor, (long)guestMinor];
            NSString *hostVersionText = [NSString stringWithFormat:@"%ld.%ld",
                                         (long)hostVersion.majorVersion, (long)hostVersion.minorVersion];
            return [self failWithError:error
                                  code:SBGuestLoaderErrorUnsupportedBinary
                               message:[NSString stringWithFormat:@"该应用需要 iOS %@，当前系统为 iOS %@",
                                        guestVersionText, hostVersionText]
                              recovery:@"请换用适配当前系统的版本"];
        }
    }

    // —— 2. 搭数据容器：建目录、HOME、tmp 软链 —————————————————————
    NSArray<NSString *> *containerSubdirs = @[
        @"Library/Caches",
        @"Library/Cookies",
        @"Documents",
        @"SystemData",
    ];
    for (NSString *subdir in containerSubdirs) {
        NSString *dirPath = [containerPath stringByAppendingPathComponent:subdir];
        NSError *mkdirError = nil;
        if (![fileManager createDirectoryAtPath:dirPath
                     withIntermediateDirectories:YES
                                      attributes:nil
                                           error:&mkdirError]) {
            return [self failWithError:error
                                  code:SBGuestLoaderErrorGuestLoadFailed
                               message:[NSString stringWithFormat:@"创建客 App 数据目录失败：%@", mkdirError.localizedDescription]
                              recovery:@"请检查存储空间后重试"];
        }
    }

    // HOME 与 CFFIXED_USER_HOME 指向客数据容器；之后 Foundation 的
    // Documents/Caches 等路径解析都会落进客容器。
    setenv("HOME", [containerPath UTF8String], 1);
    setenv("CFFIXED_USER_HOME", [containerPath UTF8String], 1);

    // tmp 用软链指回宿主 TMPDIR（宿主 tmp 随进程走，客容器内不另建一份）。
    NSString *tmpLinkPath = [containerPath stringByAppendingPathComponent:@"tmp"];
    NSString *hostTmpDir = NSTemporaryDirectory();
    struct stat linkStat;
    if (lstat([tmpLinkPath UTF8String], &linkStat) == 0) {
        remove([tmpLinkPath UTF8String]);
    }
    if (symlink([hostTmpDir UTF8String], [tmpLinkPath UTF8String]) != 0) {
        NSLog(@"[Sealbox] 客容器 tmp 软链创建失败（%@），继续启动", tmpLinkPath);
    }

    // —— 3. 给客端 Hook 留启动标记（环境变量随 dlopen 进客上下文） ———————
    NSString *hostBundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.mjorb.sealbox";
    setenv("SB_HOST_BUNDLE_ID", [hostBundleID UTF8String], 1);
    setenv("SB_GUEST_BUNDLE_ID", [bundleID UTF8String], 1);
    setenv("SB_GUEST_CONTAINER_PATH", [containerPath UTF8String], 1);
    setenv("SB_GUEST_EXEC_PATH", [guestExecPath UTF8String], 1);

    // 钥匙串组：优先用收据里随启动请求一起带来的组号；没有则按旧兜底
    //（selection 键 / 容器 UUID 哈希）处理。
    NSInteger keychainGroup = passedKeychainGroup;
    if (keychainGroup < 0 || keychainGroup >= SBKeychainGroupCount) {
        keychainGroup = -1;
        id groupObject = [[SBGuestLoader sharedDefaults] objectForKey:@"SBSelectedGuestKeychainGroup"];
        if ([groupObject isKindOfClass:[NSNumber class]]) {
            keychainGroup = [(NSNumber *)groupObject integerValue];
        }
    }
    if (keychainGroup < 0 || keychainGroup >= SBKeychainGroupCount) {
        keychainGroup = [self keychainGroupIndexForContainerUUID:containerUUID];
    }
    NSString *keychainGroupName = keychainGroup == 0
        ? SBKeychainGroupPrefix
        : [NSString stringWithFormat:@"%@.%ld", SBKeychainGroupPrefix, (long)keychainGroup];
    setenv("SB_GUEST_KEYCHAIN_GROUP", [keychainGroupName UTF8String], 1);

    // —— 4. 改写主 Bundle（NSBundle / CFBundle 指向客 App） ———————————
    NSBundle *guestBundle = [NSBundle bundleWithPath:guestAppPath];
    if (!guestBundle) {
        return [self failWithError:error
                              code:SBGuestLoaderErrorGuestLoadFailed
                           message:@"无法读取客 App 安装包"
                          recovery:@"请重新导入该应用"];
    }
    NSError *spoofError = nil;
    if (!overwriteMainNSBundle(guestBundle, &spoofError)) {
        NSString *reason = spoofError.localizedDescription ?: @"改写主 Bundle 失败";
        return [self failWithError:error
                              code:SBGuestLoaderErrorSpoofFailed
                           message:reason
                          recovery:@"该客 App 与当前系统版本不兼容，请换个版本重试"];
    }
    if (!overwriteMainCFBundle(guestBundle, &spoofError)) {
        restoreMainNSBundle();
        NSString *reason = spoofError.localizedDescription ?: @"改写主 Bundle 失败";
        return [self failWithError:error
                              code:SBGuestLoaderErrorSpoofFailed
                           message:reason
                          recovery:@"该客 App 与当前系统版本不兼容，请换个版本重试"];
    }

    // —— 5. 改写可执行路径（尽力而为：失败只记日志，不阻断启动） ————————
    NSError *execPathError = nil;
    if (!overwriteExecutablePath(guestExecPath, &execPathError)) {
        NSLog(@"[Sealbox] 改写可执行路径失败：%@，继续启动", execPathError.localizedDescription);
    }

    // —— 6. 预加载客端 Hook dylib ————————————————————————————————
    // 安装时 Installer 已把 SBGuestHooks.dylib 注入客可执行的 LC_LOAD_DYLIB，
    // dlopen 客可执行时它会自动加载；这里先试一次，失败不致命（dlopen 客可执行时还会再带一次）。
    NSString *hooksPath = [[documents stringByAppendingPathComponent:@"Tweaks"]
                           stringByAppendingPathComponent:@"SBGuestHooks.dylib"];
    if ([fileManager fileExistsAtPath:hooksPath]) {
        void *hooksHandle = dlopen([hooksPath UTF8String], RTLD_LAZY | RTLD_GLOBAL);
        if (!hooksHandle) {
            const char *dlerrorString = dlerror();
            NSLog(@"[Sealbox] 预加载客端 Hook 失败：%s", dlerrorString ? dlerrorString : "未知错误");
        }
    }

    // —— 7. dlopen 客可执行 ——————————————————————————————————————
    NSError *dlopenError = nil;
    void *guestHandle = dlopenGuest(guestExecPath, &dlopenError);
    if (!guestHandle) {
        restoreMainCFBundle();
        restoreMainNSBundle();
        restoreExecutablePath();
        if (error) {
            *error = dlopenError;
        }
        return NO;
    }
    NSError *bundleLoadError = nil;
    if (![guestBundle loadAndReturnError:&bundleLoadError]) {
        restoreMainCFBundle();
        restoreMainNSBundle();
        restoreExecutablePath();
        return [self failWithError:error
                              code:SBGuestLoaderErrorGuestLoadFailed
                           message:[NSString stringWithFormat:@"客 App 加载失败：%@", bundleLoadError.localizedDescription]
                          recovery:@"请重试，或重新导入该应用"];
    }

    // —— 8. 取入口并跳入客 main ————————————————————————————————
    uint64_t entryoff = 0;
    NSError *entryError = nil;
    if (!getAppEntryPoint(guestExecPath, &entryoff, &entryError)) {
        restoreMainCFBundle();
        restoreMainNSBundle();
        restoreExecutablePath();
        if (error) {
            *error = entryError;
        }
        return NO;
    }
    uintptr_t entryAddress = 0;
    if (!runtimeAddressForImageAtPath(guestExecPath, entryoff, &entryAddress, &entryError)) {
        restoreMainCFBundle();
        restoreMainNSBundle();
        restoreExecutablePath();
        if (error) {
            *error = entryError;
        }
        return NO;
    }

    // 加载成功：收据写成 guest-loaded，再跳入口。客 App 随后调 UIApplicationMain，
    // 像正常 App 一样跑起来；直到它退出（横杠回桌面是 exit(0)，main 不返回；
    // 只有 main 正常返回时才会走到下面的恢复逻辑）。
    [SBGuestLoader markReceiptStage:@"guest-loaded" detail:nil];

    typedef int (*SBGuestMainFn)(int argc, char **argv, char **environ);
    SBGuestMainFn guestMain = (SBGuestMainFn)entryAddress;
    char *guestArgv[] = { (char *)[guestExecPath UTF8String], NULL };
    int guestResult = guestMain(1, guestArgv, environ);

    // 客 App 的 main 返回了：恢复伪装、清掉启动标记，回桌面。
    restoreMainCFBundle();
    restoreMainNSBundle();
    restoreExecutablePath();
    [SBGuestLoader clearLaunchRequest];
    NSLog(@"[Sealbox] 客 App 已退出（返回码 %d），回到桌面", guestResult);
    return YES;
}

@end
