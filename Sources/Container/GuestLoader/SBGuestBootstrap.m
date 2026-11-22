// SBGuestBootstrap.m — 客 App 启动引导：搭环境、伪装、装 Hook、dlopen 并跳入口。
#import "SBGuestBootstrap.h"

#import <dlfcn.h>
#import <errno.h>
#import <objc/runtime.h>
#import <setjmp.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <unistd.h>

#import "SBGuestEntry.h"
#import "SBGuestLoader.h"
#import "SBGuestMainHook.h"
#import "SBGuestSessionManager.h"
#import "SBGuestUIClassifier.h"
#import "SBSwiftUIAppMainHook.h"
#import "SBDiagLog.h"
#import "SBBundleSpoof.h"
#import "SBExecPathHook.h"
#import "SealBox-Swift.h"

extern char **environ;
// CoreFoundation 的进程名全局量（与 _CFGetProcessPath 同款做法，见 SBExecPathHook.m）。
extern char **_CFGetProgname(void);

// 0.2.42：看门狗包装器用的内层方法声明（实现在文件后部；包装器在前）。
// 包装器本身也一并声明——此前两处公开入口调 inProcess 版时编译器
// 只能看到头文件（无此方法），靠隐式声明通过；本次顺手消掉该警告。
@interface SBGuestBootstrap (SBGuestWatchdogPrivate)
+ (BOOL)loadGuestWithBundleID:(NSString *)bundleID
                containerUUID:(NSString *)containerUUID
            diskDirectoryName:(NSString *)diskDirectoryName
                keychainGroup:(NSInteger)passedKeychainGroup
                    inProcess:(BOOL)inProcess
                        error:(NSError **)error;
+ (BOOL)loadGuestWithBundleIDInner:(NSString *)bundleID
                     containerUUID:(NSString *)containerUUID
                 diskDirectoryName:(NSString *)diskDirectoryName
                     keychainGroup:(NSInteger)passedKeychainGroup
                         inProcess:(BOOL)inProcess
                             error:(NSError **)error;
@end

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
static IMP g_originalSwiftArgumentsIMP = NULL;
static NSString *g_originalProcessName = nil;
static char *g_originalProgname = NULL;
static char *g_guestProgname = NULL;
// 0.2.11：客加载前存的宿主 HOME/CFFIXED_USER_HOME（setenv 改写前存，
// 失败 / 客 main 返回时还原——见 SBRestoreGuestEnvironment）。
static char *g_originalHome = NULL;
static char *g_originalFixedHome = NULL;

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
    // 0.2.26 G2：LC 同款（LCBootstrap.m:508-510）——Swift 客读
    // ProcessInfo.processInfo.arguments 走 _NSSwiftProcessInfo，不走
    // NSProcessInfo；把它 arguments 的实现也指到（已交换过的）
    // NSProcessInfo 的实现上。先存原 IMP，恢复时换回去。
    @try {
        Class swiftProcessInfo = NSClassFromString(@"_NSSwiftProcessInfo");
        if (swiftProcessInfo) {
            Method swiftArgumentsMethod = class_getInstanceMethod(swiftProcessInfo, @selector(arguments));
            if (swiftArgumentsMethod) {
                if (!g_originalSwiftArgumentsIMP) {
                    g_originalSwiftArgumentsIMP = method_getImplementation(swiftArgumentsMethod);
                }
                method_setImplementation(swiftArgumentsMethod,
                    class_getMethodImplementation([NSProcessInfo class], @selector(arguments)));
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"[Sealbox] 改写 _NSSwiftProcessInfo.arguments 失败：%@", exception.reason);
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
    // 0.2.26 G2 恢复：_NSSwiftProcessInfo.arguments 指回原实现。
    @try {
        Class swiftProcessInfo = NSClassFromString(@"_NSSwiftProcessInfo");
        if (swiftProcessInfo && g_originalSwiftArgumentsIMP) {
            Method swiftArgumentsMethod = class_getInstanceMethod(swiftProcessInfo, @selector(arguments));
            if (swiftArgumentsMethod) {
                method_setImplementation(swiftArgumentsMethod, g_originalSwiftArgumentsIMP);
                g_originalSwiftArgumentsIMP = NULL;
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"[Sealbox] 恢复 _NSSwiftProcessInfo.arguments 失败：%@", exception.reason);
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
    unsetenv("SB_HOST_HOME");
}

// 0.2.11：客加载失败 / 客 main 返回时把进程环境还回去——不止 SB_* 变量，
// 关键是 HOME/CFFIXED_USER_HOME（loadGuest 第 2 步 setenv 改写过）。0.2.10
// 真机实证：只清 SB_*、不还 HOME，失败返回后 Swift 的 documentsURL 解析
// 落进客容器，日志路径多叠了一段旧容器路径（取值层错，不只是打印层错）。
// 有存值则 setenv 回去并 free；进程本来就没 HOME（理论上到不了）则 unsetenv。
static void SBRestoreGuestEnvironment(void) {
    if (g_originalHome != NULL) {
        setenv("HOME", g_originalHome, 1);
        free(g_originalHome);
        g_originalHome = NULL;
    } else {
        unsetenv("HOME");
    }
    if (g_originalFixedHome != NULL) {
        setenv("CFFIXED_USER_HOME", g_originalFixedHome, 1);
        free(g_originalFixedHome);
        g_originalFixedHome = NULL;
    } else {
        unsetenv("CFFIXED_USER_HOME");
    }
    SBClearGuestEnvironment();
    SBDiagLogLine("客加载：进程环境已还原（HOME 指回宿主）");
}

/// 调注入件的 per-guest 安装入口 SBGuestHooksInstallForGuest（0.2.27）：
// 第二客的 SecItem/FileManager 重绑（constructor 只在首次 dlopen 跑）。
// dlsym 软依赖——注入件未导出该符号（旧版）时只记一行日志，不拦加载；
// dlsym 结果缓存一次（注入件在首次 dlopen 后即在进程里，之后一直可找）。
static void SBCallGuestHooksInstallForGuest(void) {
    typedef void (*SBGuestHooksInstallFn)(void);
    static SBGuestHooksInstallFn installFn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        installFn = (SBGuestHooksInstallFn)dlsym(RTLD_DEFAULT, "SBGuestHooksInstallForGuest");
        if (!installFn) {
            // 只记一次：旧注入件无此入口时，首客靠 constructor，次客 Hook 可能缺装。
            SBDiagLogLine([@"客加载：注入件 per-guest 安装入口未找到（dlsym 失败），首客靠 constructor，次客 Hook 可能缺装" UTF8String]);
        }
    });
    if (installFn) {
        installFn();
    }
}

/// 经 dlsym 调注入件的 SBHomeBarOverlaySetHidden（0.2.29）：restoreHostContext
/// 里藏起回桌面浮层（各失败路径与客退出时都走它，此时无客在前台）。
/// dlsym 软依赖——注入件未加载（dlopen 前失败）或旧版无此符号时静默跳过
///（浮层本就没装上）；找到一次后缓存。注意不用 dispatch_once：首次调可能
/// 在 dlopen 前（dlsym 失败），之后 dlopen 成功还得再找。
static void SBCallHomeBarOverlaySetHidden(BOOL hidden) {
    typedef void (*SBHomeBarOverlaySetHiddenFn)(BOOL);
    static SBHomeBarOverlaySetHiddenFn hideFn = NULL;
    if (!hideFn) {
        hideFn = (SBHomeBarOverlaySetHiddenFn)dlsym(RTLD_DEFAULT, "SBHomeBarOverlaySetHidden");
        if (!hideFn) {
            return;
        }
    }
    hideFn(hidden);
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

/// 0.2.44：按 bundleID＋diskDirectoryName 回查安装记录里的钥匙串组号。
/// 记录存在 App Group UserDefaults 的 SBInstalledApps JSON 里（与 Swift
/// 侧 SBStore 同一键、同一 JSON；keychainGroup 字段名与 SBInstalledApp
/// 的 Codable 键一致）。diskDirectoryName 为空时退到只按 bundleID 找首条
///（旧收据无目录名时的兜底，与 SBStore.recordLaunchResult 同款）。
/// 找不到记录或组号无效返回 -1。只在加载时调（主线程），不作缓存。
static NSInteger SBGuestRecordKeychainGroup(NSString *bundleID,
                                            NSString *diskDirectoryName) {
    if (bundleID.length == 0) {
        return -1;
    }
    NSData *data = [[SBGuestLoader sharedDefaults] objectForKey:@"SBInstalledApps"];
    if (![data isKindOfClass:[NSData class]] || data.length == 0) {
        return -1;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSArray class]]) {
        return -1;
    }
    NSDictionary *found = nil;
    for (id item in (NSArray *)object) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *dict = (NSDictionary *)item;
        if (![dict[@"bundleID"] isKindOfClass:[NSString class]] ||
            ![(NSString *)dict[@"bundleID"] isEqualToString:bundleID]) {
            continue;
        }
        if (diskDirectoryName.length > 0) {
            if ([dict[@"diskDirectoryName"] isKindOfClass:[NSString class]] &&
                [(NSString *)dict[@"diskDirectoryName"] isEqualToString:diskDirectoryName]) {
                found = dict;
                break;
            }
            if (!found) {
                found = dict; // 目录名对不上的候选，先留着当退路
            }
        } else {
            found = dict;
            break;
        }
    }
    if (!found) {
        return -1;
    }
    id group = found[@"keychainGroup"];
    if (![group isKindOfClass:[NSNumber class]]) {
        return -1;
    }
    NSInteger value = [(NSNumber *)group integerValue];
    if (value < 0 || value >= SBKeychainGroupCount) {
        return -1;
    }
    return value;
}

/// 客加载失败统一记一行（0.2.10 报错日志用）：错误码 + bundle ID +
/// 包路径 + 原因。failWithError 只造 NSError 不记日志；每个失败点
/// 先调这里再返回，出错位置由调用点的步骤号标出。
static void SBDiagLogGuestFail(SBGuestLoaderErrorCode code, NSString *bundleID, NSString *path, NSString *message) {
    SBDiagLogLine([[NSString stringWithFormat:@"客加载失败：[code=%ld] %@ %@ %@", (long)code, bundleID ?: @"", path ?: @"", message ?: @""] UTF8String]);
}

/// 读安装记录里的 entryOffset（0.2.16：打补丁去掉 LC_MAIN 后，入口偏移
/// 不再从文件里读，改从记录里取）。记录存在 App Group UserDefaults 的
/// SBInstalledApps（Swift Codable JSON 数组，键名与 SBInstalledApp 属性
/// 名一致），按 bundleID + diskDirectoryName 匹配（平行安装同名记录共存；
/// 目录名对不上时退到只按 bundleID 取首条，与 Swift 侧查记录的回退一致）。
/// 找不到、或值为 0 时返回 0，调用方回退到读文件 LC_MAIN。
+ (uint64_t)storedEntryOffsetForBundleID:(NSString *)bundleID
                      diskDirectoryName:(NSString *)diskDirectoryName {
    if (bundleID.length == 0) {
        return 0;
    }
    NSData *data = [[SBGuestLoader sharedDefaults] objectForKey:@"SBInstalledApps"];
    if (![data isKindOfClass:[NSData class]] || data.length == 0) {
        return 0;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSArray class]]) {
        return 0;
    }
    NSDictionary *bundleOnlyMatch = nil;
    for (id item in (NSArray *)object) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *record = (NSDictionary *)item;
        NSString *recordBundleID = record[@"bundleID"];
        if (![recordBundleID isKindOfClass:[NSString class]] ||
            ![recordBundleID isEqualToString:bundleID]) {
            continue;
        }
        if (bundleOnlyMatch == nil) {
            bundleOnlyMatch = record;
        }
        NSString *recordDir = record[@"diskDirectoryName"];
        if (diskDirectoryName.length == 0) {
            continue;
        }
        if (![recordDir isKindOfClass:[NSString class]] ||
            ![recordDir isEqualToString:diskDirectoryName]) {
            continue;
        }
        NSNumber *entryOffset = record[@"entryOffset"];
        if ([entryOffset isKindOfClass:[NSNumber class]]) {
            return [entryOffset unsignedLongLongValue];
        }
        return 0;
    }
    if (bundleOnlyMatch != nil) {
        NSNumber *entryOffset = bundleOnlyMatch[@"entryOffset"];
        if ([entryOffset isKindOfClass:[NSNumber class]]) {
            return [entryOffset unsignedLongLongValue];
        }
    }
    return 0;
}

/// 应用客上下文（原 loadGuest 步骤 2–5b，0.2.27 抽出）：数据容器/HOME/env、
// 主 Bundle 伪装、可执行路径、进程身份。首次加载与会话恢复共用；
// 失败时经 failAndRestore 还原已应用的部分（0.2.26 前步骤 4 失败不还原 HOME，
// 是漏口——失败返回后宿主 UI 的 documentsURL 会落进客容器）。
// keychainGroup 由调用方先解析好再传（收据/选择键/容器哈希三档）。
+ (BOOL)applyGuestContextForBundleID:(NSString *)bundleID
                       guestAppPath:(NSString *)guestAppPath
                      guestExecPath:(NSString *)guestExecPath
                      containerPath:(NSString *)containerPath
                      keychainGroup:(NSInteger)keychainGroup
                              error:(NSError **)error
                   guestBundleOut:(NSBundle **)guestBundleOut {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    // —— 2. 搭数据容器：建目录、HOME、tmp 软链 —————————————————————
    // 0.2.26 G8：LC 的四目录之外再加 Library/Preferences（LC 的
    // NSUserDefaults.m 建它；偏好 plist 落在这里，缺了它某些客写偏好失败）。
    NSArray<NSString *> *containerSubdirs = @[
        @"Library/Caches",
        @"Library/Cookies",
        @"Library/Preferences",
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
            int mkdirErrno = errno;
            SBDiagLogGuestFail(SBGuestLoaderErrorGuestLoadFailed, bundleID, dirPath,
                               [NSString stringWithFormat:@"创建客 App 数据目录失败：%@（NSError code=%ld%@）",
                                mkdirError.localizedDescription ?: @"未知原因", (long)mkdirError.code,
                                mkdirErrno != 0 ? [NSString stringWithFormat:@" errno=%d", mkdirErrno] : @""]);
            return [self failAndRestoreWithError:error
                                  code:SBGuestLoaderErrorGuestLoadFailed
                               message:[NSString stringWithFormat:@"创建客 App 数据目录失败：%@", mkdirError.localizedDescription]
                              recovery:@"请检查存储空间后重试"];
        }
    }

    // HOME 与 CFFIXED_USER_HOME 指向客数据容器；之后 Foundation 的
    // Documents/Caches 等路径解析都会落进客容器。
    // 0.2.11：先存宿主的原值（有 guard 防覆盖——若 HOME 已是客容器值，
    // 再存就把污染值当原值了），失败 / 客 main 返回时由
    // SBRestoreGuestEnvironment 还原。0.2.10 真机实证：HOME 改了没还，
    // 失败返回后 Swift 的 documentsURL 解析落进客容器，日志路径多叠了
    // 一段旧容器路径。
    if (g_originalHome == NULL) {
        const char *home = getenv("HOME");
        g_originalHome = home ? strdup(home) : NULL;
    }
    if (g_originalFixedHome == NULL) {
        const char *fixed = getenv("CFFIXED_USER_HOME");
        g_originalFixedHome = fixed ? strdup(fixed) : NULL;
    }
    // 0.2.32：宿主 tmp 必须在 HOME 改写前取——NSTemporaryDirectory() 的取值
    // 与 HOME 有关时，改写后再取会拿到客容器 tmp，软链自指成悬空链，
    // 下次安装建 tmp 目录报 516（0.2.31 真机 nread 同款；见 SBInstaller.swift）。
    NSString *hostTmpDir = NSTemporaryDirectory();
    // 0.2.26 G4b：LC 的 LC_HOME_PATH 同款——客端 Cookies hook
    //（SBFileManagerHook）要用宿主 HOME 找宿主的 Library/Cookies；
    // HOME 改写前先存一份进环境变量，失败/返回时由
    // SBRestoreGuestEnvironment 经 SBClearGuestEnvironment 清掉。
    if (g_originalHome) {
        setenv("SB_HOST_HOME", g_originalHome, 1);
    }
    setenv("HOME", [containerPath UTF8String], 1);
    setenv("CFFIXED_USER_HOME", [containerPath UTF8String], 1);

    // tmp 用软链指回宿主 TMPDIR（宿主 tmp 随进程走，客容器内不另建一份）。
    NSString *tmpLinkPath = [containerPath stringByAppendingPathComponent:@"tmp"];
    struct stat linkStat;
    if (lstat([tmpLinkPath UTF8String], &linkStat) == 0) {
        remove([tmpLinkPath UTF8String]);
    }
    if (symlink([hostTmpDir UTF8String], [tmpLinkPath UTF8String]) != 0) {
        NSLog(@"[Sealbox] 客容器 tmp 软链创建失败（%@），继续启动", tmpLinkPath);
    } else {
        SBDiagLogLine([[NSString stringWithFormat:@"客加载：客容器 tmp 软链已建（→%@）", hostTmpDir] UTF8String]);
    }
    SBDiagLogLine("客加载：数据容器就绪，HOME 已指向客容器");

    // —— 3. 给客端 Hook 留启动标记（环境变量随 dlopen 进客上下文） ———————
    NSString *hostBundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.mjorb.sealbox";
    setenv("SB_HOST_BUNDLE_ID", [hostBundleID UTF8String], 1);
    setenv("SB_GUEST_BUNDLE_ID", [bundleID UTF8String], 1);
    setenv("SB_GUEST_CONTAINER_PATH", [containerPath UTF8String], 1);
    setenv("SB_GUEST_EXEC_PATH", [guestExecPath UTF8String], 1);

    NSString *keychainGroupName = keychainGroup == 0
        ? SBKeychainGroupPrefix
        : [NSString stringWithFormat:@"%@.%ld", SBKeychainGroupPrefix, (long)keychainGroup];
    setenv("SB_GUEST_KEYCHAIN_GROUP", [keychainGroupName UTF8String], 1);

    // —— 4. 改写主 Bundle（NSBundle / CFBundle 指向客 App） ———————————
    NSBundle *guestBundle = [NSBundle bundleWithPath:guestAppPath];
    if (!guestBundle) {
        SBDiagLogGuestFail(SBGuestLoaderErrorGuestLoadFailed, bundleID, guestAppPath, @"NSBundle 读不到客 App 安装包（bundleWithPath 返回 nil）");
        return [self failAndRestoreWithError:error
                              code:SBGuestLoaderErrorGuestLoadFailed
                           message:@"无法读取客 App 安装包"
                          recovery:@"请重新导入该应用"];
    }
    NSError *spoofError = nil;
    if (!overwriteMainNSBundle(guestBundle, &spoofError)) {
        NSString *reason = spoofError.localizedDescription ?: @"改写主 Bundle 失败";
        SBDiagLogGuestFail(SBGuestLoaderErrorSpoofFailed, bundleID, guestAppPath,
                           [NSString stringWithFormat:@"NSBundle 伪装失败：%@%@", reason,
                            spoofError ? [NSString stringWithFormat:@"（NSError code=%ld）", (long)spoofError.code] : @""]);
        return [self failAndRestoreWithError:error
                              code:SBGuestLoaderErrorSpoofFailed
                           message:reason
                          recovery:@"该客 App 与当前系统版本不兼容，请换个版本重试"];
    }
    if (!overwriteMainCFBundle(guestBundle, &spoofError)) {
        restoreMainNSBundle();
        NSString *reason = spoofError.localizedDescription ?: @"改写主 Bundle 失败";
        SBDiagLogGuestFail(SBGuestLoaderErrorSpoofFailed, bundleID, guestAppPath,
                           [NSString stringWithFormat:@"CFBundle 伪装失败：%@%@", reason,
                            spoofError ? [NSString stringWithFormat:@"（NSError code=%ld）", (long)spoofError.code] : @""]);
        return [self failAndRestoreWithError:error
                              code:SBGuestLoaderErrorSpoofFailed
                           message:reason
                          recovery:@"该客 App 与当前系统版本不兼容，请换个版本重试"];
    }
    SBDiagLogLine("客加载：主 Bundle 伪装完成");

    // —— 5. 改写可执行路径（尽力而为：失败只记日志，不阻断启动） ————————
    NSError *execPathError = nil;
    if (!overwriteExecutablePath(guestExecPath, &execPathError)) {
        int execErrno = errno;
        SBDiagLogLine([[NSString stringWithFormat:@"客加载：改写可执行路径失败（继续启动）：%@ %@（NSError code=%ld%@）", guestExecPath, execPathError.localizedDescription ?: @"未知原因", (long)execPathError.code, execErrno != 0 ? [NSString stringWithFormat:@" errno=%d", execErrno] : @""] UTF8String]);
        NSLog(@"[Sealbox] 改写可执行路径失败：%@，继续启动", execPathError.localizedDescription);
    } else {
        SBDiagLogLine("客加载：可执行路径已改写为客路径");
    }

    // —— 5b. 改写进程身份（0.2.5，尽力而为）：NSProcessInfo.arguments /
    // processName 与 _CFGetProgname() 指向客可执行文件，让客 App 读到的
    // 进程身份与它自己一致。_CFGetProcessPath() 已在第 5 步里直写过。
    SBRewriteProcessIdentity(guestExecPath);
    SBDiagLogLine("客加载：进程身份已改写为客应用");
    if (guestBundleOut) {
        *guestBundleOut = guestBundle;
    }
    return YES;

}

/// 把进程上下文还原成宿主自己的（伪装/路径/身份/HOME/env）。各还原函数自带
/// “未改写过即空操作”守卫，重复调无害。
+ (void)installHostDelegateWindowGetter {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = NSClassFromString(@"SwiftUI.AppDelegate");
        if (!cls) {
            SBDiagLogLine("宿主 delegate window 补丁：SwiftUI.AppDelegate 类未找到，不装");
            return;
        }
        if ([cls instancesRespondToSelector:@selector(window)]) {
            SBDiagLogLine("宿主 delegate window 补丁：SwiftUI.AppDelegate 已有 window，不装");
            return;
        }
        // 用 block 作 IMP：getter 返回当前 keyWindow；setter 把收到的窗变 key 可见
        //（legacy delegate.window 语义：delegate 的 window 就是 key window）。
        // 类型编码 "@@:"（getter）与 "v@:@"（setter）。类上已有 window 时不动。
        id getterBlock = ^id(id _self) {
            return [UIApplication sharedApplication].keyWindow;
        };
        IMP getterIMP = imp_implementationWithBlock(getterBlock);
        BOOL getterAdded = class_addMethod(cls, @selector(window), getterIMP, "@@:");
        id setterBlock = ^(id _self, UIWindow *window) {
            if (window) {
                window.hidden = NO;
                [window makeKeyAndVisible];
            }
        };
        IMP setterIMP = imp_implementationWithBlock(setterBlock);
        BOOL setterAdded = class_addMethod(cls, @selector(setWindow:), setterIMP, "v@:@");
        SBDiagLogLine([[NSString stringWithFormat:@"宿主 delegate window 补丁：SwiftUI.AppDelegate 已补 window（getter=%@ setter=%@）",
                        getterAdded ? @"是" : @"否", setterAdded ? @"是" : @"否"] UTF8String]);
    });
}

+ (void)restoreHostContext {
    restoreMainCFBundle();
    restoreMainNSBundle();
    restoreExecutablePath();
    SBRestoreProcessIdentity();
    SBRestoreGuestEnvironment();
    // 0.2.29：无客激活时藏起回桌面浮层——各失败路径与客退出时都走这里；
    // 此时无客在前台（失败=客没起来，退出=客已走），藏起安全；浮层窗口
    // windowLevel 高，不藏会盖在宿主弹窗上吞点击（0.2.28 真机：重绑护栏
    // 失败后浮层仍在，弹窗按钮点不了）。窗口级透传（SBHomeBarOverlay.m）
    // 是第一道防线，这里是第二道。
    SBCallHomeBarOverlaySetHidden(YES);
    // 0.2.30（MJ 00:07 立规：客加载每一步都要写日志，不许有静默步骤）：
    // 还原本身记一行——失败路径与客退出都走这里，崩在还原之后也能定位。
    SBDiagLogLine([@"客加载：已恢复宿主环境（主 Bundle/可执行路径/进程身份/环境已还原，浮层已藏）" UTF8String]);
}

/// 失败 + 还原：先还原已应用的客上下文，再按 failWithError 造错返回 NO。
+ (BOOL)failAndRestoreWithError:(NSError **)error
                           code:(SBGuestLoaderErrorCode)code
                        message:(NSString *)message
                       recovery:(NSString *)recovery {
    [self restoreHostContext];
    return [self failWithError:error code:code message:message recovery:recovery];
}

+ (BOOL)loadGuestWithBundleID:(NSString *)bundleID
                containerUUID:(NSString *)containerUUID
            diskDirectoryName:(NSString *)diskDirectoryName
                keychainGroup:(NSInteger)passedKeychainGroup
                        error:(NSError **)error {
    return [self loadGuestWithBundleID:bundleID
                         containerUUID:containerUUID
                     diskDirectoryName:diskDirectoryName
                         keychainGroup:passedKeychainGroup
                             inProcess:NO
                                 error:error];
}

/// 进程内加载（0.2.27）：与 loadGuestWithBundleID 同流程，但在 dlopen 后、
// 跳 main 前装好 UIApplicationMain 拦截；hook 激活后客 main 返回≠退出，
// 不恢复环境、不清收据（激活时会话侧已记成功），返回 YES 表示客已在前台。
+ (BOOL)loadGuestInProcessWithBundleID:(NSString *)bundleID
                         containerUUID:(NSString *)containerUUID
                     diskDirectoryName:(nullable NSString *)diskDirectoryName
                         keychainGroup:(NSInteger)keychainGroup
                                 error:(NSError **)error {
    return [self loadGuestWithBundleID:bundleID
                         containerUUID:containerUUID
                     diskDirectoryName:diskDirectoryName
                         keychainGroup:keychainGroup
                             inProcess:YES
                                 error:error];
}

+ (BOOL)loadGuestWithBundleID:(NSString *)bundleID
                containerUUID:(NSString *)containerUUID
            diskDirectoryName:(NSString *)diskDirectoryName
                keychainGroup:(NSInteger)passedKeychainGroup
                    inProcess:(BOOL)inProcess
                        error:(NSError **)error {
    // 0.2.42 看门狗包装器：点开流程（inProcess）开始前武装，成功后由
    // 会话侧解除（completeActivation／failActivation／SwiftUI 激活出口），
    // 同步失败（内层返回 NO）在这里解除——内层十余处 return NO 全被
    // 这一处兜住，不用逐个加解除。成功且仍在进程内（YES＋inProcess）时
    // 不解除：scene 驱动（0.4 秒补查→手动 willConnect）还在后头，
    // 看门狗须守到激活完成或失败。新鲜进程（!inProcess）不武装。
    if (inProcess) {
        SBDiagLogWatchdogArm([bundleID UTF8String]);
    }
    BOOL loaded = [self loadGuestWithBundleIDInner:bundleID
                                     containerUUID:containerUUID
                                 diskDirectoryName:diskDirectoryName
                                     keychainGroup:passedKeychainGroup
                                         inProcess:inProcess
                                             error:error];
    if (!loaded || !inProcess) {
        SBDiagLogWatchdogDisarmForGuest([bundleID UTF8String]);
    }
    return loaded;
}

/// 0.2.42：看门狗熔断用的客可执行指纹（文件名＋大小＋修改时间）与宿主版本。
/// 格式与 willConnect 指纹同款，但属看门狗熔断记录，两套记录不互通。
/// 只在点开流程内用（武装后补填指纹、卡死熔断检查），不作他用。
static NSString *SBGuestWatchdogFingerprintForExecPath(NSString *guestExecPath) {
    NSDictionary *attrs = nil;
    if (guestExecPath.length > 0) {
        attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:guestExecPath error:nil];
    }
    NSNumber *size = attrs[NSFileSize];
    NSDate *mtime = attrs[NSFileModificationDate];
    return [NSString stringWithFormat:@"%@|%lld|%.0f",
            guestExecPath.lastPathComponent ?: @"?",
            size ? (long long)size.longLongValue : -1,
            mtime ? mtime.timeIntervalSince1970 : -1];
}

static NSString *SBGuestWatchdogHostVersion(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *marketing = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *build = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    return [NSString stringWithFormat:@"%@(%@)", marketing ?: @"?", build ?: @"?"];
}

+ (BOOL)loadGuestWithBundleIDInner:(NSString *)bundleID
                     containerUUID:(NSString *)containerUUID
                 diskDirectoryName:(NSString *)diskDirectoryName
                     keychainGroup:(NSInteger)passedKeychainGroup
                         inProcess:(BOOL)inProcess
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
        SBDiagLogGuestFail(SBGuestLoaderErrorBundleNotFound, bundleID, guestAppPath, @"客 App 安装包不在磁盘");
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
        SBDiagLogGuestFail(SBGuestLoaderErrorBundleNotFound, bundleID, guestExecPath, @"客 App 可执行文件不在磁盘");
        return [self failWithError:error
                              code:SBGuestLoaderErrorBundleNotFound
                           message:@"找不到客 App 可执行文件，请重新安装"
                          recovery:@"重新导入该应用"];
    }
    if (is32BitMachOAtPath(guestExecPath)) {
        SBDiagLogGuestFail(SBGuestLoaderErrorUnsupportedBinary, bundleID, guestExecPath, @"该应用是 32 位应用，需要 JIT 才能运行");
        return [self failWithError:error
                              code:SBGuestLoaderErrorUnsupportedBinary
                           message:@"该应用是 32 位应用，需要 JIT 才能运行"
                          recovery:@"请用 Seal 开启 JIT 后重试，或换用 64 位版本"];
    }
    // 0.2.42：看门狗熔断检查——上次点开卡死过的客（指纹与宿主版本均未变）
    // 不再重进，干净失败；重装／升级（指纹或版本已变）即自动重试。
    // 指纹先补填给看门狗（超时写熔断标记时用）；检查在搭客上下文之前，
    // 熔断的客连环境都不搭。
    NSString *watchdogFingerprint = SBGuestWatchdogFingerprintForExecPath(guestExecPath);
    NSString *watchdogHostVersion = SBGuestWatchdogHostVersion();
    SBDiagLogWatchdogSetGuestFingerprint([watchdogFingerprint UTF8String],
                                        [watchdogHostVersion UTF8String]);
    char stuckStep[128] = {0};
    if (SBDiagLogIsGuestStuckForGuest([bundleID UTF8String],
                                     [watchdogFingerprint UTF8String],
                                     [watchdogHostVersion UTF8String],
                                     stuckStep, sizeof(stuckStep))) {
        NSString *stuckReason = [NSString stringWithFormat:
            @"该应用上次打开时卡住了（%@），已跳过；重新导入或等后续版本可再试",
            stuckStep[0] != '\0' ? [NSString stringWithUTF8String:stuckStep] : @"未知步骤"];
        SBDiagLogGuestFail(SBGuestLoaderErrorGuestLoadFailed, bundleID, guestExecPath, stuckReason);
        return [self failWithError:error
                              code:SBGuestLoaderErrorGuestLoadFailed
                           message:stuckReason
                          recovery:@"请重新导入该应用，或等后续版本"];
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
            SBDiagLogGuestFail(SBGuestLoaderErrorUnsupportedBinary, bundleID, guestExecPath,
                               [NSString stringWithFormat:@"该应用需要 iOS %@，当前系统为 iOS %@", guestVersionText, hostVersionText]);
            return [self failWithError:error
                                  code:SBGuestLoaderErrorUnsupportedBinary
                               message:[NSString stringWithFormat:@"该应用需要 iOS %@，当前系统为 iOS %@",
                                        guestVersionText, hostVersionText]
                              recovery:@"请换用适配当前系统的版本"];
        }
    }

    // —— 2–5b. 应用客上下文（数据容器/HOME/env、主 Bundle 伪装、可执行路径、进程身份）——
    // 0.2.27：抽成 applyGuestContext，首次加载与会话恢复共用；失败时还原已应用的部分。
    // 0.2.44：钥匙串组只认记录，不哈希兜底——安装分配（首个空闲组）与
    // 容器 UUID 哈希（djb2%128）是两套算法，兜底走偏即换组，登录态读不到、
    // 看起来像“数据无法保留”。解析顺序：传入组号（收据/记录）→ selection
    // 键 → 按 bundleID＋diskDirectoryName 回查记录 → 哈希（只留给无记录
    // 可查的极端情形，且日志明文写“无记录，哈希兜底，登录可能不延续”）。
    NSInteger keychainGroup = passedKeychainGroup;
    if (keychainGroup < 0 || keychainGroup >= SBKeychainGroupCount) {
        keychainGroup = -1;
        id groupObject = [[SBGuestLoader sharedDefaults] objectForKey:@"SBSelectedGuestKeychainGroup"];
        if ([groupObject isKindOfClass:[NSNumber class]]) {
            keychainGroup = [(NSNumber *)groupObject integerValue];
        }
    }
    if (keychainGroup < 0 || keychainGroup >= SBKeychainGroupCount) {
        keychainGroup = SBGuestRecordKeychainGroup(bundleID, diskDirectoryName);
        if (keychainGroup >= 0) {
            SBDiagLogLine([[NSString stringWithFormat:@"钥匙串组：%@ 记录查到组 %ld（收据缺组号，按记录补）",
                            bundleID, (long)keychainGroup] UTF8String]);
        }
    }
    if (keychainGroup < 0 || keychainGroup >= SBKeychainGroupCount) {
        keychainGroup = [self keychainGroupIndexForContainerUUID:containerUUID];
        SBDiagLogLine([[NSString stringWithFormat:@"钥匙串组：%@ 无记录可查，哈希兜底组 %ld，登录可能不延续",
                        bundleID, (long)keychainGroup] UTF8String]);
    }
    NSBundle *guestBundle = nil;
    if (![self applyGuestContextForBundleID:bundleID
                               guestAppPath:guestAppPath
                              guestExecPath:guestExecPath
                              containerPath:containerPath
                              keychainGroup:keychainGroup
                                      error:error
                           guestBundleOut:&guestBundle]) {
        return NO;
    }

    // —— 6. 预加载客端 Hook dylib：0.2.6 已删除 —————————————————————
    // 0.2.5 在这里 dlopen SBGuestHooks.dylib，但它的 constructor 会把
    // 4 组 Hook（NSUserDefaults / NSFileManager 方法交换、钥匙串重绑、
    // 底部横杠回桌面浮层）装进宿主进程；客加载随后失败时这些 Hook 没有
    // 卸载路径——宿主 UI 带着客 Hook 跑：设置读客 suite、底部上滑直接
    // exit(0)，看上去就是“报错后又闪退”（0.2.5 真机追加报）。
    // 删掉预加载不丢功能：安装时 Hook 件已注入客可执行的 LC_LOAD_DYLIB，
    // 第 7 步 dlopen 客可执行时 dyld 会把它当依赖加载，constructor 在客
    // 上下文里装 Hook；客加载失败时 Hook 件根本不进宿主进程。

    // —— 6.5. 预加载（0.2.26 G7，0.2.27 补进程内路）———————————————————
    // LC 同款：MetalANGLE 须在客 dlopen 前先加载。launchGuestInProcess 把路径写进
    // 宿主 HOME/Library/preloadLibraries.txt；新鲜进程由 main.m 在启动时读它；
    // 进程内路 main.m 早已跑过，这里在 dlopen 前读并逐行 dlopen 后删文件。
    // 路径取 SB_HOST_HOME（步骤 2 存的宿主 HOME）——此时 HOME 已指客容器。
    {
        const char *hostHome = getenv("SB_HOST_HOME");
        if (hostHome && hostHome[0] != '\0') {
            NSString *preloadPath = [[NSString stringWithUTF8String:hostHome]
                stringByAppendingPathComponent:@"Library/preloadLibraries.txt"];
            NSString *preloadContent = [NSString stringWithContentsOfFile:preloadPath
                                                                  encoding:NSUTF8StringEncoding
                                                                     error:nil];
            if (preloadContent) {
                for (NSString *line in [preloadContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                    NSString *lib = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (lib.length == 0) {
                        continue;
                    }
                    if (!dlopen([lib UTF8String], RTLD_LAZY | RTLD_GLOBAL)) {
                        const char *dlErr = dlerror();
                        SBDiagLogLine([[NSString stringWithFormat:@"预加载库失败：%@（%@）", lib, dlErr ? [NSString stringWithUTF8String:dlErr] : @"?"] UTF8String]);
                    } else {
                        SBDiagLogLine([[NSString stringWithFormat:@"预加载库：%@", lib] UTF8String]);
                    }
                }
                [[NSFileManager defaultManager] removeItemAtPath:preloadPath error:nil];
            }
        }
    }

    // —— 7. dlopen 客可执行 ——————————————————————————————————————
    // 0.2.24：进 dlopen 前先落一个标记文件（带客 bundle ID，写完 fsync）；
    // dlopen 一返回立刻清掉。进程若死在 dlopen 里（0.2.23 闪退），标记留
    // 下来，下次启动 SBDiagLogBeginRun 会认出来并记“上次启动死在 dlopen 里”。
    SBDiagLogLine([[NSString stringWithFormat:@"客加载：进入 dlopen：%@", guestExecPath] UTF8String]);
    // 0.2.42 看门狗“dlopen”步，阈值 10s（0.2.40 实测 dlopen 约 150ms；
    // 大客＋冷盘放宽到 10s）。
    SBDiagLogWatchdogStepBegin("dlopen", 10.0);
    SBDiagLogMarkDlopenEntry([bundleID UTF8String]);
    NSError *dlopenError = nil;
    void *guestHandle = dlopenGuest(guestExecPath, &dlopenError);
    SBDiagLogClearDlopenEntry();
    SBDiagLogWatchdogStepEnd("dlopen");
    // 0.2.44（A 档 1）：dlopen 慢（步超时）不 exit、不跳 main——看门狗只置
    // slow 标志、写 slow 记录；这里消费标志位，干净失败“加载超时，请重试”，
    // 可立即再点。句柄已拿到也照此处理：镜像留在进程里（永不 dlclose），
    // 下次点开 dyld 按路径去重、直接复用，不丢东西。
    if (SBDiagLogWatchdogConsumeSlowTimeout()) {
        SBDiagLogLine([[NSString stringWithFormat:@"客加载：%@ dlopen 步超时（慢加载），干净失败，可重试",
                        bundleID] UTF8String]);
        [self restoreHostContext];
        return [self failWithError:error
                              code:SBGuestLoaderErrorGuestLoadFailed
                           message:@"加载超时，请重试"
                          recovery:@"该应用打开较慢，请再点一次"];
    }
    if (!guestHandle) {
        SBDiagLogGuestFail(SBGuestLoaderErrorGuestLoadFailed, bundleID, guestExecPath,
                           [NSString stringWithFormat:@"dlopen 失败：%@", dlopenError.localizedDescription ?: @"未知错误"]);
        [self restoreHostContext];
        if (error) {
            *error = dlopenError;
        }
        return NO;
    }
    // 0.2.26 G1：LC 同款（LCBootstrap.m:622）——dlopen 客后、load 前显式触发
    // NSUserDefaults 的 +initialize，修某些应用的动态属性问题。
    [NSUserDefaults performSelector:@selector(initialize)];
    NSError *bundleLoadError = nil;
    if (![guestBundle loadAndReturnError:&bundleLoadError]) {
        SBDiagLogGuestFail(SBGuestLoaderErrorGuestLoadFailed, bundleID, guestExecPath,
                           [NSString stringWithFormat:@"NSBundle 加载失败：%@（NSError code=%ld）", bundleLoadError.localizedDescription ?: @"未知原因", (long)bundleLoadError.code]);
        [self restoreHostContext];
        return [self failWithError:error
                              code:SBGuestLoaderErrorGuestLoadFailed
                           message:[NSString stringWithFormat:@"客 App 加载失败：%@", bundleLoadError.localizedDescription]
                          recovery:@"请重试，或重新导入该应用"];
    }

    // 0.2.27：per-guest 注入件安装（第二客的 SecItem/FileManager 重绑——
// constructor 只在首次 dlopen 跑，次客靠这里补装；幂等，首客是空操作）。
// dlsym 软依赖：找不到（旧注入件）时只记一行日志，不拦加载。
    SBCallGuestHooksInstallForGuest();

    // 0.2.28：进程内加载——dlopen 后、跳 main 前按客 UI 类型装拦截。
    // SwiftUI 客装 App.main 重绑（跳原入口必崩，改嵌 App 场景）；装不上
    // 直接干净失败，不跳 main。UIKit/Flutter 客装 UIApplicationMain 拦截
    //（0.2.30：统一走 SBChainedFixupRebind，C 符号＋Swift 覆盖层符号都试，
    // 主镜像不成再扫 Frameworks；装不上同样干净失败，不跳 main——0.2.29 前
    // 这里忽略安装返回值直接跳 main，第二遍 UIApplicationMain 断言崩）。
    BOOL isSwiftUIGuest = NO;
    // 0.2.42 看门狗“hook-install”步，阈值 2s（纯内存重绑，毫秒级）。
    SBDiagLogWatchdogStepBegin("hook-install", 2.0);
    if (inProcess) {
        SBGuestMainHookContext *hookContext = [[SBGuestMainHookContext alloc] init];
        hookContext.bundleID = bundleID;
        hookContext.containerUUID = containerUUID;
        hookContext.diskDirectoryName = diskDirectoryName;
        hookContext.keychainGroup = keychainGroup;
        hookContext.guestAppPath = guestAppPath;
        hookContext.guestExecPath = guestExecPath;
        hookContext.containerPath = containerPath;
        hookContext.guestHandle = guestHandle;
        hookContext.guestBundle = guestBundle;
        SBGuestUIType uiType = SBGuestUITypeForGuestExecutable(guestExecPath);
        if (uiType == SBGuestUITypeSwiftUI) {
            isSwiftUIGuest = YES;
            SBDiagLogLine([[NSString stringWithFormat:@"客加载：%@ 是 SwiftUI 应用，装 App.main 重绑（嵌 App 场景，不跳原入口）",
                            bundleID] UTF8String]);
            if (!SBSwiftUIAppMainHookInstallForGuestImage(NULL, hookContext)) {
                // 护栏：重绑装不上 → 干净失败，记日志＋弹错，绝不跳 main。
                [self restoreHostContext];
                if (error) {
                    *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorGuestLoadFailed, @"加载客 App",
                                                    @"该应用是 SwiftUI 应用，暂不支持进程内启动",
                                                    @"该应用暂不支持在虚拟机内打开，请等待后续版本");
                }
                SBDiagLogLine([[NSString stringWithFormat:@"客加载失败：%@ SwiftUI 应用，App.main 重绑未装上（护栏干净失败）",
                                bundleID] UTF8String]);
                return NO;
            }
        } else {
            if (!SBGuestMainHookInstallForGuestImage(NULL, hookContext, uiType)) {
                // 护栏：拦截装不上 → 干净失败，记日志＋弹错，绝不跳 main
                //（0.2.30：与 SwiftUI 护栏一致；0.2.29 前这里忽略返回值直接
                // 跳 main，第二遍 UIApplicationMain “Dispatch queue already
                // set” 断言崩，见 SealBox-2026-11-21-000419.ips）。
                [self restoreHostContext];
                if (error) {
                    *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorGuestLoadFailed, @"加载客 App",
                                                    @"该应用的启动拦截未装上，暂不支持进程内启动",
                                                    @"该应用暂不支持在虚拟机内打开，请等待后续版本");
                }
                SBDiagLogLine([[NSString stringWithFormat:@"客加载失败：%@ UIKit/Flutter 应用，UIApplicationMain 拦截未装上（护栏干净失败）",
                                bundleID] UTF8String]);
                return NO;
            }
        }
    }
    SBDiagLogWatchdogStepEnd("hook-install");

    // 0.2.33：exit 截获（SBGuestMainHook.h）——Flutter Runner 生成的 main 在
    // 覆盖层返回后无条件调 exit，不截获则替身一返回进程就退出（原型 0233，
    // OmoFun Runner 入口反汇编已证）。装不上（客没 import exit）不拦加载，
    // 只记一行；武装/解除在下面跳 main 处。
    SBGuestExitTrapInstallForGuestImage(NULL, guestExecPath, bundleID);

    // —— 8. 取入口并跳入客 main ————————————————————————————————
    uint64_t entryoff = 0;
    NSError *entryError = nil;
    // 0.2.16：打补丁已去掉 LC_MAIN，入口偏移优先从安装记录里取；旧记录
    // （entryOffset 为空，文件仍带 LC_MAIN）回退到读文件 LC_MAIN。
    uint64_t storedEntryoff = [self storedEntryOffsetForBundleID:bundleID
                                               diskDirectoryName:diskDirectoryName];
    if (storedEntryoff != 0) {
        entryoff = storedEntryoff;
        SBDiagLogLine([[NSString stringWithFormat:@"客入口：entryoff 取自安装记录 0x%llx（打补丁时已去掉 LC_MAIN）", (unsigned long long)entryoff] UTF8String]);
    } else if (!getAppEntryPoint(guestExecPath, &entryoff, &entryError)) {
        NSInteger entryCode = entryError ? entryError.code : SBGuestLoaderErrorEntryPointNotFound;
        SBDiagLogGuestFail((SBGuestLoaderErrorCode)entryCode, bundleID, guestExecPath,
                           [NSString stringWithFormat:@"取客 App 入口失败：%@", entryError.localizedDescription ?: @"未知原因"]);
        [self restoreHostContext];
        if (error) {
            *error = entryError;
        }
        return NO;
    }
    uintptr_t entryAddress = 0;
    if (!runtimeAddressForImageAtPath(guestExecPath, entryoff, &entryAddress, &entryError)) {
        NSInteger entryCode = entryError ? entryError.code : SBGuestLoaderErrorEntryPointNotFound;
        SBDiagLogGuestFail((SBGuestLoaderErrorCode)entryCode, bundleID, guestExecPath,
                           [NSString stringWithFormat:@"取客 App 入口运行地址失败：entryoff=0x%llx 原因：%@", (unsigned long long)entryoff, entryError.localizedDescription ?: @"未知原因"]);
        [self restoreHostContext];
        if (error) {
            *error = entryError;
        }
        return NO;
    }

    // 加载成功：收据写成 guest-loaded，再跳入口。客 App 随后调 UIApplicationMain，
    // 像正常 App 一样跑起来；直到它退出（横杠回桌面是 exit(0)，main 不返回；
    // 只有 main 正常返回时才会走到下面的恢复逻辑）。0.2.33 补充：Flutter 客
    // main 收尾的 exit 由截获转成 longjmp，同样回到这里（“经 exit 截获”）。
    [SBGuestLoader markReceiptStage:@"guest-loaded" detail:nil];
    SBDiagLogLine([[NSString stringWithFormat:@"客加载：跳入客 main（入口 0x%lx）", (unsigned long)entryAddress] UTF8String]);

    typedef int (*SBGuestMainFn)(int argc, char **argv, char **environ);
    SBGuestMainFn guestMain = (SBGuestMainFn)entryAddress;
    char *guestArgv[] = { (char *)[guestExecPath UTF8String], NULL };
    // 0.2.33：客 main 一返回立即记一行（跳回后的第一行）——有此行说明 bootstrap
    // 拿回了控制权、死在之后；无此行说明死在客 main 收尾里。exit 截获先武装：
    // Runner main 收尾的 exit 会 siglongjmp 回这里，按 main 返回走同一分流。
    // 注意：setjmp/longjmp 之间改过的非 volatile 局部在跳回后值不确定——
    // guestResult/exitTrapped 只在跳回后（else 分支里）才赋值，安全；
    // inProcess/isSwiftUIGuest/bundleID 等在 setjmp 前已定、中间没改过。
    int guestResult = 0;
    BOOL exitTrapped = NO;
    SBGuestExitTrapArm();
    if (sigsetjmp(*SBGuestExitTrapEnv(), 1) == 0) {
        guestResult = guestMain(1, guestArgv, environ);
    } else {
        guestResult = SBGuestExitTrapCode();
        exitTrapped = YES;
    }
    SBGuestExitTrapDisarm();
    SBDiagLogLine([[NSString stringWithFormat:@"客 main 已返回（result=%d%@）",
                    guestResult, exitTrapped ? @"，经 exit 截获" : @""] UTF8String]);

    // 客 App 的 main 返回了。分四种（0.2.27 三种＋0.2.28 SwiftUI 一种）：
    // ① 进程内 + hook 已激活：main 返回≠退出（hook 返回 0 即回），客在前台运行，
    //    不恢复环境、不清收据、不记成功（激活时会话侧已记），直接返回 YES。
    // ② 进程内 + hook 同步激活失败：按加载失败返回（error 已由 hook 置好），恢复环境。
    // ③ 进程内 SwiftUI 客：嵌客激活→YES（同①）；未激活→失败（嵌入失败用
    //    hook 的错；main 返回而 hook 未触发、无错——静默无操作不是成功——
    //    也按失败处理，护栏文案），恢复环境。
    // ④ 其余（新鲜进程真退出 / 客 main 未调 UIApplicationMain 即返回）：恢复伪装、清掉启动标记，记成功。
    // 0.2.28：SwiftUI 客 main 返回后的分流（在 UIKit 分流之前）。
    if (inProcess && isSwiftUIGuest) {
        if (SBSwiftUIAppMainHookDidActivate()) {
            SBDiagLogLine([[NSString stringWithFormat:@"客 main 已返回（SwiftUI 嵌客已激活，%@ 在前台运行，不恢复环境）", bundleID] UTF8String]);
            return YES;
        }
        NSError *swiftUIError = SBSwiftUIAppMainHookActivationError();
        [self restoreHostContext];
        SBDiagLogLine([[NSString stringWithFormat:@"客加载失败：%@ SwiftUI 嵌客未激活（%@）", bundleID, swiftUIError.localizedDescription ?: @"main 返回而 hook 未触发"] UTF8String]);
        if (error) {
            *error = swiftUIError ?: SBGuestLoaderErrorMake(SBGuestLoaderErrorGuestLoadFailed, @"加载客 App",
                                                            @"该应用是 SwiftUI 应用，暂不支持进程内启动",
                                                            @"该应用暂不支持在虚拟机内打开，请等待后续版本");
        }
        return NO;
    }
    if (inProcess && SBGuestMainHookDidActivate()) {
        SBDiagLogLine([[NSString stringWithFormat:@"客 main 已返回（进程内拦截已激活，%@ 在前台运行，不恢复环境）", bundleID] UTF8String]);
        return YES;
    }
    if (inProcess) {
        NSError *hookError = SBGuestMainHookActivationError();
        if (hookError) {
            [self restoreHostContext];
            SBDiagLogLine([[NSString stringWithFormat:@"客加载失败：%@ 进程内激活失败（%@）", bundleID, hookError.localizedDescription] UTF8String]);
            if (error) {
                *error = hookError;
            }
            return NO;
        }
    }
    [self restoreHostContext];
    [SBGuestLoader clearLaunchRequest];
    SBDiagLogLine([[NSString stringWithFormat:@"客 App 已退出（返回码 %d），回到桌面", guestResult] UTF8String]);
    NSLog(@"[Sealbox] 客 App 已退出（返回码 %d），回到桌面", guestResult);
    // 0.2.26 C：客 main 跑完返回，记成功、清标记、护栏计数归零（Swift 侧）。
    [SBGuestLaunchPreflight noteGuestLaunchedSuccessfullyWithBundleID:bundleID
                                                        containerUUID:containerUUID
                                                    diskDirectoryName:diskDirectoryName
                                                          returnCode:guestResult];
    return YES;
}

@end
