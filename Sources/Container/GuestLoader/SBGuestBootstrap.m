// SBGuestBootstrap.m — 客 App 启动引导：搭环境、伪装、装 Hook、dlopen 并跳入口。
#import "SBGuestBootstrap.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <unistd.h>

#import "SBGuestEntry.h"
#import "SBGuestLoader.h"
#import "SBDiagLog.h"
#import "SBBundleSpoof.h"
#import "SBExecPathHook.h"

extern char **environ;
// CoreFoundation 的进程名全局量（与 _CFGetProcessPath 同款做法，见 SBExecPathHook.m）。
extern char **_CFGetProgname(void);

// 钥匙串组名前缀（与契约 SBConstants 一致：com.mjorb.sealbox.shared[.N]）。
static NSString * const SBKeychainGroupPrefix = @"com.mjorb.sealbox.shared";
// 钥匙串组总数（与契约 keychainGroupCount 一致）。
static const NSInteger SBKeychainGroupCount = 128;

// —— 进程身份改写（0.2.5，LiveContainer 同款做法，尽力而为） ————————————
// NSProcessInfo.arguments 是只读属性：把它的 getter 换成返回客 argv（[客可执行路径]）。
// processName 有公开 setter；_CFGetProgname() 直写 CF 的进程名全局量。
// _CFGetProcessPath() 的直写已在第 5 步的 overwriteExecutablePath 里做过，不重复。
// 任何一步失败都不阻断启动——客 App 读到的进程身份不完整也比启动失败强。
//
// 0.2.6：改写必须可恢复——客加载失败后宿主进程继续跑 UI，进程身份留在客名
// 上是错的；_CFGetProgname 的 free-then-strdup 在第二次点图标时会 free 掉
// CF 全局量还指着的缓冲（0.2.5 修过的 g_guestExecPath 同款问题）。
// 所以改写前先存原始值（原 IMP、原 processName、原 progname 指针），
// 失败 / 客 main 返回时 SBRestoreProcessIdentity 全数还原。
// strdup 新名字在先、再赋值、最后才 free 旧缓冲：中间没有悬空指针。
static NSArray *g_sbGuestArguments = nil;
static IMP g_originalArgumentsIMP = NULL;
static NSString *g_originalProcessName = nil;
static char *g_originalProgname = NULL;
static char *g_guestProgname = NULL;

static NSArray *SBGuestProcessInfoArguments(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return g_sbGuestArguments ?: @[];
}

static void SBRewriteProcessIdentity(NSString *guestExecPath) {
    if (guestExecPath.length == 0) {
        return;
    }
    // arguments：swizzle getter（先存原 IMP，恢复时换回去）。
    @try {
        Method argumentsMethod = class_getInstanceMethod([NSProcessInfo class], @selector(arguments));
        if (argumentsMethod) {
            if (!g_originalArgumentsIMP) {
                g_originalArgumentsIMP = method_getImplementation(argumentsMethod);
            }
            g_sbGuestArguments = @[ guestExecPath ];
            method_setImplementation(argumentsMethod, (IMP)SBGuestProcessInfoArguments);
        }
    } @catch (NSException *exception) {
        NSLog(@"[Sealbox] 改写 NSProcessInfo.arguments 失败：%@", exception.reason);
    }
    // processName：公开 setter（先存原名）。
    @try {
        if (!g_originalProcessName) {
            g_originalProcessName = [[NSProcessInfo processInfo] processName];
        }
        [[NSProcessInfo processInfo] setProcessName:[guestExecPath lastPathComponent]];
    } @catch (NSException *exception) {
        NSLog(@"[Sealbox] 改写 processName 失败：%@", exception.reason);
    }
    // _CFGetProgname()：直写 CF 进程名全局量（通常是可执行文件名）。
    // 先 strdup 新名字、再赋值、最后 free 旧的客名字缓冲：*progname 在任何
    // 时刻都指着有效内存；原 progname 指针存起来，恢复时指回去。
    char **progname = _CFGetProgname();
    if (progname && *progname) {
        if (!g_originalProgname) {
            g_originalProgname = *progname;
        }
        char *newName = strdup([[guestExecPath lastPathComponent] UTF8String]);
        if (newName) {
            char *oldGuestName = g_guestProgname;
            g_guestProgname = newName;
            *progname = newName;
            free(oldGuestName);
        }
    }
}

/// 把进程身份还原成宿主自己的（客加载失败 / 客 main 返回时调）。
/// 未改写过时是空操作；恢复失败也不抛，尽力而为。
static void SBRestoreProcessIdentity(void) {
    @try {
        Method argumentsMethod = class_getInstanceMethod([NSProcessInfo class], @selector(arguments));
        if (argumentsMethod && g_originalArgumentsIMP) {
            method_setImplementation(argumentsMethod, g_originalArgumentsIMP);
            g_originalArgumentsIMP = NULL;
        }
    } @catch (NSException *exception) {
        NSLog(@"[Sealbox] 恢复 NSProcessInfo.arguments 失败：%@", exception.reason);
    }
    @try {
        if (g_originalProcessName) {
            [[NSProcessInfo processInfo] setProcessName:g_originalProcessName];
            g_originalProcessName = nil;
        }
    } @catch (NSException *exception) {
        NSLog(@"[Sealbox] 恢复 processName 失败：%@", exception.reason);
    }
    // progname 先指回原指针，再 free 客名字缓冲（顺序反了会悬空）。
    char **progname = _CFGetProgname();
    if (progname && g_originalProgname) {
        *progname = g_originalProgname;
        g_originalProgname = NULL;
    }
    if (g_guestProgname) {
        free(g_guestProgname);
        g_guestProgname = NULL;
    }
    g_sbGuestArguments = nil;
}

/// 清掉第 3 步设的客环境变量：失败后宿主继续跑，留着它们会让之后加载的
/// Hook 件误以为还在客上下文里（SB_GUEST_BUNDLE_ID 是 Hook 件 constructor
/// 的安装开关）。恢复失败路径不依赖它，但清掉更干净。
static void SBClearGuestEnvironment(void) {
    unsetenv("SB_GUEST_BUNDLE_ID");
    unsetenv("SB_GUEST_CONTAINER_PATH");
    unsetenv("SB_GUEST_EXEC_PATH");
    unsetenv("SB_GUEST_KEYCHAIN_GROUP");
    unsetenv("SB_HOST_BUNDLE_ID");
}

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
    SBDiagLogLine([[NSString stringWithFormat:@"客加载：开始加载 %@（包 %@）", bundleID, guestAppPath] UTF8String]);
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
    SBDiagLogLine("客加载：数据容器就绪，HOME 已指向客容器");

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
        SBDiagLogLine([[NSString stringWithFormat:@"客加载失败：NSBundle 伪装失败：%@", reason] UTF8String]);
        return [self failWithError:error
                              code:SBGuestLoaderErrorSpoofFailed
                           message:reason
                          recovery:@"该客 App 与当前系统版本不兼容，请换个版本重试"];
    }
    if (!overwriteMainCFBundle(guestBundle, &spoofError)) {
        restoreMainNSBundle();
        NSString *reason = spoofError.localizedDescription ?: @"改写主 Bundle 失败";
        SBDiagLogLine([[NSString stringWithFormat:@"客加载失败：CFBundle 伪装失败：%@", reason] UTF8String]);
        return [self failWithError:error
                              code:SBGuestLoaderErrorSpoofFailed
                           message:reason
                          recovery:@"该客 App 与当前系统版本不兼容，请换个版本重试"];
    }
    SBDiagLogLine("客加载：主 Bundle 伪装完成");

    // —— 5. 改写可执行路径（尽力而为：失败只记日志，不阻断启动） ————————
    NSError *execPathError = nil;
    if (!overwriteExecutablePath(guestExecPath, &execPathError)) {
        SBDiagLogLine([[NSString stringWithFormat:@"客加载：改写可执行路径失败（继续启动）：%@", execPathError.localizedDescription] UTF8String]);
        NSLog(@"[Sealbox] 改写可执行路径失败：%@，继续启动", execPathError.localizedDescription);
    } else {
        SBDiagLogLine("客加载：可执行路径已改写为客路径");
    }

    // —— 5b. 改写进程身份（0.2.5，尽力而为）：NSProcessInfo.arguments /
    // processName 与 _CFGetProgname() 指向客可执行文件，让客 App 读到的
    // 进程身份与它自己一致。_CFGetProcessPath() 已在第 5 步里直写过。
    SBRewriteProcessIdentity(guestExecPath);
    SBDiagLogLine("客加载：进程身份已改写为客应用");

    // —— 6. 预加载客端 Hook dylib：0.2.6 已删除 —————————————————————
    // 0.2.5 在这里 dlopen SBGuestHooks.dylib，但它的 constructor 会把
    // 4 组 Hook（NSUserDefaults / NSFileManager 方法交换、钥匙串重绑、
    // 底部横杠回桌面浮层）装进宿主进程；客加载随后失败时这些 Hook 没有
    // 卸载路径——宿主 UI 带着客 Hook 跑：设置读客 suite、底部上滑直接
    // exit(0)，看上去就是“报错后又闪退”（0.2.5 真机追加报）。
    // 删掉预加载不丢功能：安装时 Hook 件已注入客可执行的 LC_LOAD_DYLIB，
    // 第 7 步 dlopen 客可执行时 dyld 会把它当依赖加载，constructor 在客
    // 上下文里装 Hook；客加载失败时 Hook 件根本不进宿主进程。

    // —— 7. dlopen 客可执行 ——————————————————————————————————————
    NSError *dlopenError = nil;
    void *guestHandle = dlopenGuest(guestExecPath, &dlopenError);
    if (!guestHandle) {
        restoreMainCFBundle();
        restoreMainNSBundle();
        restoreExecutablePath();
        SBRestoreProcessIdentity();
        SBClearGuestEnvironment();
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
        SBRestoreProcessIdentity();
        SBClearGuestEnvironment();
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
        SBRestoreProcessIdentity();
        SBClearGuestEnvironment();
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
        SBRestoreProcessIdentity();
        SBClearGuestEnvironment();
        if (error) {
            *error = entryError;
        }
        return NO;
    }

    // 加载成功：收据写成 guest-loaded，再跳入口。客 App 随后调 UIApplicationMain，
    // 像正常 App 一样跑起来；直到它退出（横杠回桌面是 exit(0)，main 不返回；
    // 只有 main 正常返回时才会走到下面的恢复逻辑）。
    [SBGuestLoader markReceiptStage:@"guest-loaded" detail:nil];
    SBDiagLogLine([[NSString stringWithFormat:@"客加载：跳入客 main（入口 0x%lx）", (unsigned long)entryAddress] UTF8String]);

    typedef int (*SBGuestMainFn)(int argc, char **argv, char **environ);
    SBGuestMainFn guestMain = (SBGuestMainFn)entryAddress;
    char *guestArgv[] = { (char *)[guestExecPath UTF8String], NULL };
    int guestResult = guestMain(1, guestArgv, environ);

    // 客 App 的 main 返回了：恢复伪装、清掉启动标记，回桌面。
    restoreMainCFBundle();
    restoreMainNSBundle();
    restoreExecutablePath();
    SBRestoreProcessIdentity();
    SBClearGuestEnvironment();
    [SBGuestLoader clearLaunchRequest];
    SBDiagLogLine([[NSString stringWithFormat:@"客 App 已退出（返回码 %d），回到桌面", guestResult] UTF8String]);
    NSLog(@"[Sealbox] 客 App 已退出（返回码 %d），回到桌面", guestResult);
    return YES;
}

@end
