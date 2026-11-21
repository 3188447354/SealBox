// SBGuestSessionManager.m — 客 App 后台会话注册表（0.2.27 进程内进客）。
//
// 状态：
//   loaded=YES, guestWindow=nil            → 正在激活（异步 scene 驱动待完成）
//   loaded=YES, active=YES, guestWindow!=nil → 前台运行
//   loaded=YES, active=NO,  guestWindow!=nil → 后台保留（再点即恢复）
// 会话是内存态：进程被杀后注册表即失，下次启动 guest-loaded 收据由路由静默清除，
// 进宿主界面（不跨进程恢复）。
#import "SBGuestSessionManager.h"

#import <objc/message.h>

#import "SBGuestBootstrap.h"
#import "SBGuestLoader.h"
#import "SBDiagLog.h"
#import "SealBox-Swift.h"

NSString * const SBGuestReturnToHostRequestedNotification = @"SBGuestReturnToHostRequested";
NSString * const SBGuestDidEnterBackgroundNotification = @"SBGuestDidEnterBackground";
NSString * const SBGuestDidEnterForegroundNotification = @"SBGuestDidEnterForeground";
NSString * const SBGuestActivationFailedNotification = @"SBGuestActivationFailed";
NSString * const SBGuestActivationFailedMessageKey = @"SBGuestActivationFailedMessage";

// 0.2.27：收据阶段与 selection 键的字面量与 SBGuestLoader.m / Swift 侧一致
//（那两处是 static / 字面量，未进公共头；原型核对三处一致）。
static NSString * const SBGuestReceiptStageGuestFailed = @"guest-failed";
static NSString * const SBKeySelectedGuestBundleID = @"SBSelectedGuestBundleID";
static NSString * const SBKeySelectedGuestContainer = @"SBSelectedGuestContainer";

// scene 驱动：系统路先试，0.4 秒后无窗则手动 willConnect。
static const NSTimeInterval SBGuestSceneSystemPathWaitSeconds = 0.4;

@implementation SBGuestMainHookContext
@end

@implementation SBGuestSession
@end

@interface SBGuestSessionManager ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, SBGuestSession *> *sessions;
@property (nonatomic, copy, nullable) NSString *currentBundleID;
/// 宿主状态（首次激活时保存一次；UIKit 持有，弱引用）。
@property (nonatomic, weak, nullable) id hostAppDelegate;
@property (nonatomic, weak, nullable) UIWindow *hostWindow;
@property (nonatomic, weak, nullable) UIWindowScene *hostScene;
@property (nonatomic, weak, nullable) id hostSceneDelegate;
@end

@implementation SBGuestSessionManager

+ (instancetype)sharedManager {
    static SBGuestSessionManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[SBGuestSessionManager alloc] init];
        manager.sessions = [NSMutableDictionary dictionary];
        [[NSNotificationCenter defaultCenter] addObserver:manager
                                                 selector:@selector(handleReturnToHostRequested:)
                                                     name:SBGuestReturnToHostRequestedNotification
                                                   object:nil];
    });
    return manager;
}

- (nullable SBGuestSession *)sessionForBundleID:(NSString *)bundleID {
    return self.sessions[bundleID];
}

- (nullable SBGuestSession *)currentSession {
    if (self.currentBundleID.length == 0) {
        return nil;
    }
    return self.sessions[self.currentBundleID];
}

#pragma mark - 宿主状态

/// 首次激活时保存宿主 delegate/窗口/scene（之后不再覆盖——宿主是同一个）。
- (void)saveHostStateIfNeeded {
    // 0.2.37：补丁在 main.m 里已装过一次；这里再调一次是兜底（main.m 时
    // SwiftUI 类若尚未注册，dispatch_once 的重试只在这里发生一次）。
    [SBGuestBootstrap installHostDelegateWindowGetter];
    if (self.hostAppDelegate && self.hostWindow) {
        return;
    }
    UIApplication *app = [UIApplication sharedApplication];
    self.hostAppDelegate = app.delegate;
    self.hostWindow = app.keyWindow;
    UIWindowScene *scene = self.hostWindow.windowScene;
    if (!scene) {
        for (UIScene *candidate in app.connectedScenes) {
            if ([candidate isKindOfClass:[UIWindowScene class]] &&
                candidate.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)candidate;
                break;
            }
        }
    }
    self.hostScene = scene;
    self.hostSceneDelegate = scene.delegate;
}

/// 宿主窗口（弱引用已空时回退：第一只非客窗口、普通层级）。
- (nullable UIWindow *)fallbackHostWindow {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.windowLevel != UIWindowLevelNormal) {
            continue;
        }
        BOOL isGuestWindow = NO;
        for (SBGuestSession *session in self.sessions.allValues) {
            if (session.guestWindow == window) {
                isGuestWindow = YES;
                break;
            }
        }
        if (!isGuestWindow) {
            return window;
        }
    }
    return nil;
}

- (void)restoreHostUI {
    UIApplication *app = [UIApplication sharedApplication];
    if (self.hostAppDelegate) {
        app.delegate = self.hostAppDelegate;
    }
    if (self.hostScene && self.hostSceneDelegate) {
        self.hostScene.delegate = self.hostSceneDelegate;
    }
    UIWindow *hostWindow = self.hostWindow ?: [self fallbackHostWindow];
    if (hostWindow) {
        hostWindow.hidden = NO;
        [hostWindow makeKeyAndVisible];
    }
    // 0.2.36：恢复完记一行可核查的结果——0.2.35 真机 Flutter 失败后“恢复宿主界面”
    // 只是一句断言，宿主窗到底 key/可见与否无从核对；黑屏时下份日志必须能定位。
    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：恢复宿主界面：宿主窗 %@（key=%@ hidden=%@），app.keyWindow=%@",
                    hostWindow ? NSStringFromClass([hostWindow class]) : @"无",
                    hostWindow.isKeyWindow ? @"是" : @"否",
                    hostWindow.hidden ? @"是" : @"否",
                    app.keyWindow ? NSStringFromClass([app.keyWindow class]) : @"无"] UTF8String]);
}

#pragma mark - 客窗查找

/// 激活前后新增的窗口即客窗（浮层窗口在 dlopen 时已建，在 windowsBefore 内，不会被误认）。
- (nullable UIWindow *)findGuestWindowForSession:(SBGuestSession *)session {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *keyWindow = app.keyWindow;
    if (keyWindow && keyWindow != self.hostWindow &&
        ![session.windowsBeforeActivation containsObject:keyWindow]) {
        return keyWindow;
    }
    for (UIWindow *window in app.windows) {
        if (window == self.hostWindow) {
            continue;
        }
        if ([session.windowsBeforeActivation containsObject:window]) {
            continue;
        }
        if (window.windowLevel == UIWindowLevelNormal) {
            return window;
        }
    }
    return nil;
}

/// 0.2.36：窗口清单（失败/恢复时核查黑屏用）：每只窗一行——层级、hidden、key、frame、rootVC。
- (void)logWindowInventoryWithTag:(NSString *)tag {
    UIApplication *app = [UIApplication sharedApplication];
    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：窗口清单（%@）：共 %lu 只窗",
                    tag, (unsigned long)app.windows.count] UTF8String]);
    for (UIWindow *window in app.windows) {
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：窗口清单（%@）：%@ level=%.0f hidden=%@ key=%@ frame=%@ rootVC=%@",
                        tag, NSStringFromClass([window class]), window.windowLevel,
                        window.hidden ? @"是" : @"否", window.isKeyWindow ? @"是" : @"否",
                        NSStringFromCGRect(window.frame),
                        window.rootViewController ? NSStringFromClass([window.rootViewController class]) : @"无"] UTF8String]);
    }
}

#pragma mark - 激活完成 / 失败

- (void)completeActivationForSession:(SBGuestSession *)session {
    if (session.guestWindow) {
        return; // 已完成过（0.4 秒补查与手动路可能重复触发）。
    }
    UIWindow *guestWindow = [self findGuestWindowForSession:session];
    if (!guestWindow) {
        return;
    }
    session.guestWindow = guestWindow;
    session.guestScene = guestWindow.windowScene ?: self.hostScene;
    // 系统路（requestSceneSessionActivation）建的窗：scene delegate 是 UIKit
    // 刚挂上的客 scene delegate，从 scene 上取下来留着，供恢复时重挂。
    if (!session.guestSceneDelegate && session.guestScene &&
        session.guestScene.delegate && session.guestScene.delegate != self.hostSceneDelegate) {
        session.guestSceneDelegate = session.guestScene.delegate;
    }
    session.active = YES;
    self.currentBundleID = session.bundleID;
    [session.guestWindow makeKeyAndVisible];
    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 已激活（客窗 %@，scene %@）",
                    session.bundleID, NSStringFromCGRect(session.guestWindow.frame),
                    session.guestScene ? @"宿主 scene" : @"无 scene"] UTF8String]);
    // 激活即证明启动成功：记成功、护栏归零（Swift 侧桥；与 0.2.26 C 的
    // main 返回记成功同款，只是触发点从 main 返回改到激活完成）。
    [SBGuestLaunchPreflight noteGuestActivatedInProcessWithBundleID:session.bundleID
                                                      containerUUID:session.containerUUID
                                                  diskDirectoryName:session.diskDirectoryName];
    [[NSNotificationCenter defaultCenter] postNotificationName:SBGuestDidEnterForegroundNotification
                                                        object:nil];
}

- (void)failActivationForSession:(SBGuestSession *)session message:(NSString *)message {
    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 激活失败（%@），恢复宿主界面",
                    session.bundleID, message] UTF8String]);
    // 0.2.36：先藏起激活期间客新建的窗口（再恢复宿主界面）——0.2.35 真机 Flutter
    // 干净失败后日志写“恢复宿主界面”，MJ 看到的却是黑屏：restoreHostUI 只把宿主窗
    // 变 key/可见，不藏客窗；客在 willConnect 里建了窗（哪怕没成 key、非 Normal 层级、
    // 没 rootVC 的黑窗）也会盖在宿主窗上面。按 windowsBeforeActivation 认：
    // 激活前已有的窗与宿主窗不动，其余一律 hidden=YES。会话还没从表里删，
    // 此时 guestWindow 判定仍有效；清掉后再扫会把客窗当普通窗漏掉。
    [self logWindowInventoryWithTag:@"激活失败前"];
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window == self.hostWindow) {
            continue;
        }
        if ([session.windowsBeforeActivation containsObject:window]) {
            continue;
        }
        window.hidden = YES;
    }
    [self.sessions removeObjectForKey:session.bundleID];
    if ([self.currentBundleID isEqualToString:session.bundleID]) {
        self.currentBundleID = nil;
    }
    [self restoreHostUI];
    [self logWindowInventoryWithTag:@"恢复宿主界面后"];
    [SBGuestBootstrap restoreHostContext];
    // 写 guest-failed 收据（宿主进桌面后按收据弹错）；selection 清掉，收据留着。
    [SBGuestLoader markReceiptStage:SBGuestReceiptStageGuestFailed detail:message];
    NSUserDefaults *defaults = [SBGuestLoader sharedDefaults];
    [defaults removeObjectForKey:SBKeySelectedGuestBundleID];
    [defaults removeObjectForKey:SBKeySelectedGuestContainer];
    [defaults synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:SBGuestActivationFailedNotification
                                                        object:nil
                                                      userInfo:@{ SBGuestActivationFailedMessageKey: message }];
}

#pragma mark - scene 驱动

/// 客 Info.plist 的 UISceneConfigurations 里取第一个应用角色配置（delegate 未
/// 实现 configurationForConnectingSceneSession 时的回退）。
- (nullable UISceneConfiguration *)sceneConfigurationFromGuestPlist:(SBGuestSession *)session {
    NSString *plistPath = [session.guestAppPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSDictionary *manifest = plist[@"UIApplicationSceneManifest"];
    NSDictionary *configsByRole = manifest[@"UISceneConfigurations"];
    if (![configsByRole isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSArray *configs = configsByRole[@"UIWindowSceneSessionRoleApplication"];
    if (![configs isKindOfClass:[NSArray class]] || configs.count == 0) {
        // 应用角色没有，取任意角色的第一项。
        for (id value in configsByRole.allValues) {
            if ([value isKindOfClass:[NSArray class]] && [(NSArray *)value count] > 0) {
                configs = (NSArray *)value;
                break;
            }
        }
    }
    if (![configs isKindOfClass:[NSArray class]] || configs.count == 0) {
        return nil;
    }
    NSDictionary *configDict = configs[0];
    if (![configDict isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSString *name = configDict[@"UISceneConfigurationName"];
    NSString *delegateClassName = configDict[@"UISceneDelegateClassName"];
    if (![delegateClassName isKindOfClass:[NSString class]] || delegateClassName.length == 0) {
        return nil;
    }
    Class delegateClass = NSClassFromString(delegateClassName);
    if (!delegateClass) {
        return nil;
    }
    UISceneConfiguration *config = [[UISceneConfiguration alloc]
        initWithName:[name isKindOfClass:[NSString class]] && name.length > 0 ? name : @"Default Configuration"
                    sessionRole:UIWindowSceneSessionRoleApplication];
    config.delegateClass = delegateClass;
    return config;
}

/// 手动路：在宿主 scene 上换入客 scene delegate、调 willConnect，让客建窗。
/// 0.2.35：全程记日志——0.2.34 真机 MediaStormCamera 两回都在“走手动
/// willConnect”后断住、进程以 -crashed 结尾，本方法入口无日志，死在哪一步
/// 无从判断。下份日志必须能证明窗出没出：每一步都有行；死在 willConnect 内
/// 的特征是“调用…”行之后无“已返回”行（Swift trap 不是 NSException，
/// @try/@catch 抓不住，只能靠前后两行定位）。
/// 本方法只在主线程跑（0.4 秒补查经 dispatch_get_main_queue() 调度，
/// activateGuestWithContext 入口亦有主线程守卫），willConnect 的线程无问题。
/// 0.2.37：willConnect 熔断用的客可执行指纹——文件名＋大小＋修改时间。
/// 重装/重导换了二进制即变指纹，拦截记录自动失效、重试一次。
- (NSString *)willConnectFingerprintForSession:(SBGuestSession *)session {
    NSDictionary *attrs = nil;
    if (session.guestExecPath.length > 0) {
        attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:session.guestExecPath error:nil];
    }
    NSNumber *size = attrs[NSFileSize];
    NSDate *mtime = attrs[NSFileModificationDate];
    return [NSString stringWithFormat:@"%@|%lld|%.0f",
            session.guestExecPath.lastPathComponent ?: @"?",
            size ? (long long)size.longLongValue : -1,
            mtime ? mtime.timeIntervalSince1970 : -1];
}

/// 0.2.37：宿主版本（MARKETING_VERSION＋build）——宿主升级后拦截记录自动失效、重试一次。
- (NSString *)willConnectHostVersion {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *marketing = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *build = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    return [NSString stringWithFormat:@"%@(%@)", marketing ?: @"?", build ?: @"?"];
}

- (void)driveSceneManuallyForSession:(SBGuestSession *)session {
    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 手动 willConnect：入口（客窗已有=%@）",
                    session.bundleID, session.guestWindow ? @"是" : @"否"] UTF8String]);
    if (session.guestWindow) {
        return;
    }
    // 0.2.37：willConnect 熔断（通用规则，不按应用名）——Swift trap 抓不住，
    // 死过一次 willConnect 的客再调一次还是死。两档：
    //  (1) 上次启动死在该客 willConnect 里（BeginRun 残留标记）：写拦截记录，干净失败；
    //  (2) 拦截记录在位且客可执行指纹＋宿主版本均未变：跳过调用，干净失败。
    // 背景：彩云 7.63.2 反汇编核实，willConnect 内两处 as! 式强转都是条件式
    // （_swift_dynamicCastObjCClass 条件原语＋cbz 早退），不可能是死因；
    // 死在强转之后的深层路径（detectLaunch 树 / 7.63.5 增量），离线无法再钉，
    // 需真机 .ips——熔断是 0.2.37 能保证“不再闪退”的唯一办法。
    NSString *fingerprint = [self willConnectFingerprintForSession:session];
    NSString *hostVersion = [self willConnectHostVersion];
    const char *staleGuest = SBDiagLogStaleWillConnectGuest();
    if (staleGuest && staleGuest[0] != '\0' &&
        [session.bundleID isEqualToString:[NSString stringWithUTF8String:staleGuest]]) {
        SBDiagLogBlockWillConnectForGuest([session.bundleID UTF8String],
                                         [fingerprint UTF8String],
                                         [hostVersion UTF8String]);
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 手动 willConnect：熔断——上次启动死在 willConnect 里，已写拦截记录，本次跳过调用",
                        session.bundleID] UTF8String]);
        [self failActivationForSession:session
                               message:@"上次打开时闪退（死在客 App 启动步骤里），本次跳过该步骤以免再次闪退"];
        return;
    }
    if (SBDiagLogIsWillConnectBlockedForGuest([session.bundleID UTF8String],
                                             [fingerprint UTF8String],
                                             [hostVersion UTF8String])) {
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 手动 willConnect：熔断——拦截记录在位（指纹与宿主版本均未变），跳过调用",
                        session.bundleID] UTF8String]);
        [self failActivationForSession:session
                               message:@"该应用的启动步骤上次导致闪退，已跳过；重新导入或升级后可再试"];
        return;
    }
    UIWindowScene *scene = self.hostScene;
    if (!scene) {
        [self failActivationForSession:session message:@"找不到宿主 scene，无法为客 App 创建窗口"];
        return;
    }
    UISceneSession *sceneSession = scene.session;
    if (!sceneSession) {
        // 0.2.35：nil session 传给 Swift 写的 scene delegate，若其强解会陷阱
        // 杀进程，且 @try 抓不住——宁可干净失败，不传 nil 进去。
        [self failActivationForSession:session message:@"宿主 scene 无会话，无法为客 App 创建窗口（scene.session 为空）"];
        return;
    }
    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 手动 willConnect：宿主 scene 与 session 就绪",
                    session.bundleID] UTF8String]);
    // 空 options：UISceneConnectionOptions 的 -init 被标 NS_UNAVAILABLE
    //（只有系统才造它），但实现仍在——NS_UNAVAILABLE 只是编译期标记，
    // 用 objc_msgSend 绕过它直接调运行时 -init（0.2.27 fixup 5，
    // run 44733218725 红于 [[alloc] init]）。得一个非 nil 的空对象：
    // Swift 写的 scene delegate 若强解 options 不会崩；读
    // userActivities/URL 上下文只会拿到空值。造不出时直接判激活失败，
    // 不把 nil options 传给 delegate。
    UISceneConnectionOptions *options = ((id (*)(id, SEL))objc_msgSend)([UISceneConnectionOptions alloc], @selector(init));
    if (!options) {
        [self failActivationForSession:session message:@"无法创建 scene 连接选项"];
        return;
    }
    UIApplication *app = [UIApplication sharedApplication];
    UISceneConfiguration *config = nil;
    id delegate = session.guestAppDelegate;
    if ([delegate respondsToSelector:@selector(application:configurationForConnectingSceneSession:options:)]) {
        @try {
            config = [delegate application:app
                configurationForConnectingSceneSession:sceneSession
                                               options:options];
        } @catch (NSException *exception) {
            SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 问 delegate 要 scene 配置抛异常（%@），改读 Info.plist",
                            session.bundleID, exception.reason] UTF8String]);
            config = nil;
        }
    }
    if (!config) {
        config = [self sceneConfigurationFromGuestPlist:session];
    }
    if (!config || !config.delegateClass) {
        [self failActivationForSession:session
                               message:@"客 App 未提供 scene 配置，无法创建窗口"];
        return;
    }
    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 手动 willConnect：scene 配置已取（delegate 类 %@）",
                    session.bundleID, NSStringFromClass(config.delegateClass)] UTF8String]);
    id sceneDelegate = [[config.delegateClass alloc] init];
    if (!sceneDelegate) {
        [self failActivationForSession:session message:@"客 scene delegate 创建失败"];
        return;
    }
    session.guestSceneDelegate = sceneDelegate;
    scene.delegate = sceneDelegate;
    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 手动 willConnect：客 scene delegate 已创建并挂到宿主 scene",
                    session.bundleID] UTF8String]);
    @try {
        if ([sceneDelegate respondsToSelector:@selector(scene:willConnectToSession:options:)]) {
            // 0.2.36：调用前环境快照——死在 willConnect 里时，下份日志必须能看到
            // 调用瞬间的全部前置状态（0.2.35 MediaStormCamera 只剩“调用…”一行，
            // app.delegate 是谁、session 配置是谁的、options 是否空，全靠猜）。
            SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 手动 willConnect：调用前环境（app.delegate=%@ scene.session.configuration=%@/%@ options url=%lu activity=%lu keyWindow=%@ scenes=%lu）",
                            session.bundleID,
                            NSStringFromClass([app.delegate class]),
                            sceneSession.configuration.name ?: @"无",
                            sceneSession.configuration.delegateClass ? NSStringFromClass(sceneSession.configuration.delegateClass) : @"无",
                            (unsigned long)options.URLContexts.count,
                            (unsigned long)options.userActivities.count,
                            app.keyWindow ? @"有" : @"无",
                            (unsigned long)app.connectedScenes.count] UTF8String]);
            // 0.2.37：调用前先决条件（通用——任何 UIKit scene 客的 willConnect 都可能写
            // `scene as! UIWindowScene` / `delegate as! AppDelegate` 无条件强转；
            // Swift trap @try 抓不住，调前验不过就干净失败、不调）：
            //  (1) scene 必须是 UIWindowScene；(2) app.delegate 必须是客 AppDelegate 类实例。
            //  (2) 不满足时先把会话里存的客 delegate 实例重装上去再验一次——激活与
            //  0.4 秒补查之间若有谁换了 delegate，重装能救回来；仍不满足才干净失败。
            //  通过时记一行：下份日志若仍死在 willConnect 里，先决条件已排除、直指深层路径。
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                [self failActivationForSession:session message:@"宿主 scene 不是 UIWindowScene，跳过客 willConnect（客内 as! 强转会闪退）"];
                return;
            }
            id guestDelegate = session.guestAppDelegate;
            if (!guestDelegate) {
                [self failActivationForSession:session message:@"客 AppDelegate 未在会话里，无法核验 willConnect 先决条件，跳过调用"];
                return;
            }
            if (![app.delegate isKindOfClass:[guestDelegate class]]) {
                SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 手动 willConnect：先决条件不满足（app.delegate=%@，客 delegate 类=%@），重装客 delegate 再验",
                                session.bundleID, NSStringFromClass([app.delegate class]), NSStringFromClass([guestDelegate class])] UTF8String]);
                app.delegate = guestDelegate;
                if (![app.delegate isKindOfClass:[guestDelegate class]]) {
                    [self failActivationForSession:session message:@"客 AppDelegate 未在位（重装后仍不是客类），跳过客 willConnect（客内 as! 强转会闪退）"];
                    return;
                }
                SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 手动 willConnect：客 delegate 已重装，先决条件通过",
                                session.bundleID] UTF8String]);
            } else {
                SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 手动 willConnect：先决条件通过（scene 是 UIWindowScene，app.delegate 是客 %@ 实例）",
                                session.bundleID, NSStringFromClass([guestDelegate class])] UTF8String]);
            }
            SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 手动 willConnect：调用客 scene delegate willConnect（%@）",
                            session.bundleID, NSStringFromClass([sceneDelegate class])] UTF8String]);
            // 0.2.36：进入标记（SBDiagLog dlopen 标记同款）——Swift trap 抓不住，
            // 死在 willConnect 里时标记留下来，下次启动明确报“上次死在 willConnect 里”。
            SBDiagLogMarkWillConnectEntry([session.bundleID UTF8String]);
            [sceneDelegate scene:scene willConnectToSession:sceneSession options:options];
            SBDiagLogClearWillConnectEntry();
            SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 手动 willConnect：客 scene delegate willConnect 已返回",
                            session.bundleID] UTF8String]);
            // 0.2.37：willConnect 成功返回——若曾有拦截记录（指纹/版本已变才走到这里），清掉。
            SBDiagLogClearWillConnectBlockForGuest([session.bundleID UTF8String]);
        } else {
            SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 手动 willConnect：客 scene delegate 未实现 willConnect，跳过调用直接找窗",
                            session.bundleID] UTF8String]);
        }
    } @catch (NSException *exception) {
        SBDiagLogClearWillConnectEntry();
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ scene willConnect 抛异常（%@）",
                        session.bundleID, exception.reason] UTF8String]);
        [self failActivationForSession:session
                               message:[NSString stringWithFormat:@"客 App 创建窗口失败（%@）", exception.reason ?: @"未知原因"]];
        return;
    }
    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 手动 willConnect：willConnect 结束，开始找客窗",
                    session.bundleID] UTF8String]);
    UIWindow *guestWindow = [self findGuestWindowForSession:session];
    if (guestWindow) {
        [self completeActivationForSession:session];
    } else {
        [self failActivationForSession:session message:@"客 App 未创建窗口（scene 驱动无窗）"];
    }
}

/// 系统路 0.4 秒后补查：有窗即完成，无窗走手动路。
- (void)checkSceneSystemPathForSession:(SBGuestSession *)session {
    // 会话已被清掉（失败/切换）则不再动。
    if (self.sessions[session.bundleID] != session) {
        // 0.2.33：之前这里静默返回，下份日志会误读成“死在替身返回到补查之间”；记一行区分。
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 0.4 秒补查：会话已不在（被清掉/切换），不补查",
                        session.bundleID] UTF8String]);
        return;
    }
    if (session.guestWindow) {
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 0.4 秒补查：客窗已有（已激活），不重复",
                        session.bundleID] UTF8String]);
        return;
    }
    // 0.2.32：补查入口记一行——0.2.31 phoenix 三回都没走到这里（死在之前），
    // 有此行即证明进程活到了 0.4 秒后；无此行，死在替身返回到补查之间。
    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 0.4 秒补查开始（客窗是否出现见下文）",
                    session.bundleID] UTF8String]);
    if ([self findGuestWindowForSession:session]) {
        [self completeActivationForSession:session];
        return;
    }
    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 系统 scene 路 0.4 秒无窗，走手动 willConnect",
                    session.bundleID] UTF8String]);
    [self driveSceneManuallyForSession:session];
}

#pragma mark - 激活

/// 0.2.36：客 storyboard 名——正常启动时 UIKit 读它建窗。先读顶层
/// UIMainStoryboardFile（OmoFun 等老模板），没有再扫 scene 配置的
/// UISceneStoryboardFile（新模板放这里；sceneConfigurationFromGuestPlist
/// 只取 name＋delegateClass，把它丢了）。
- (nullable NSString *)storyboardNameForSession:(SBGuestSession *)session {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:
        [session.guestAppPath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *name = plist[@"UIMainStoryboardFile"];
    if ([name isKindOfClass:[NSString class]] && name.length > 0) {
        return name;
    }
    NSDictionary *manifest = plist[@"UIApplicationSceneManifest"];
    NSDictionary *configsByRole = manifest[@"UISceneConfigurations"];
    if ([configsByRole isKindOfClass:[NSDictionary class]]) {
        for (id value in configsByRole.allValues) {
            if (![value isKindOfClass:[NSArray class]]) continue;
            for (id config in (NSArray *)value) {
                if (![config isKindOfClass:[NSDictionary class]]) continue;
                NSString *sceneStoryboard = config[@"UISceneStoryboardFile"];
                if ([sceneStoryboard isKindOfClass:[NSString class]] && sceneStoryboard.length > 0) {
                    return sceneStoryboard;
                }
            }
        }
    }
    return nil;
}

/// 0.2.36：Flutter 客建窗（#3/#4）——正常启动时 UIKit 做的事，宿主进程内
/// 从未替客做过。OmoFun 反汇编实证（Flutter 3.35.7）：FlutterSceneDelegate.
/// willConnect 只把 app.delegate.window 上已有的 rootVC 搬进新 scene 窗，
/// rootVC 为 nil 时在 cbz 处静默 return——0.2.35 真机 phoenix/nread 正是
/// “willConnect 已返回→开始找客窗→未创建窗口”。didFinishLaunching 只做插件
/// 注册＋转发，不建窗；窗是 UIKit 加载 Main.storyboard 建的（建 UIWindow、
/// 实例化 FlutterViewController、设 rootVC、赋给 delegate.window）。
/// 本方法只在 didFinishLaunching 之后、findGuestWindow 之前跑，且仅当尚无客窗
/// 时才建：didFinishLaunching 里已建窗的 pre-scene 客不受影响；无 storyboard
/// 的客（纯代码 UI）直接返回 NO，走原有 scene 路／手动 willConnect。
/// 返回 YES＝已建窗（随后的 findGuestWindow 即命中，直接完成激活，不再走手动
/// willConnect）；NO＝没建（原因已记日志，调用方继续原流程）。
- (BOOL)buildGuestWindowFromStoryboardForSession:(SBGuestSession *)session {
    if ([self findGuestWindowForSession:session]) {
        return YES; // 已有窗，不重复建。
    }
    NSString *storyboardName = [self storyboardNameForSession:session];
    if (!storyboardName) {
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 无 storyboard（UIMainStoryboardFile/UISceneStoryboardFile 均无），不建窗，走 scene 路",
                        session.bundleID] UTF8String]);
        return NO;
    }
    UIWindowScene *windowScene = self.hostWindow.windowScene ?: session.guestScene;
    if (!windowScene) {
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 有 storyboard（%@）但无 windowScene，无法建窗",
                        session.bundleID, storyboardName] UTF8String]);
        return NO;
    }
    @try {
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:storyboardName bundle:session.guestBundle];
        UIViewController *rootVC = [storyboard instantiateInitialViewController];
        if (!rootVC) {
            SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ storyboard（%@）初始 VC 为空，不建窗",
                            session.bundleID, storyboardName] UTF8String]);
            return NO;
        }
        UIWindow *window = [[UIWindow alloc] initWithWindowScene:windowScene];
        window.rootViewController = rootVC;
        [window makeKeyAndVisible];
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ storyboard 建窗（%@）：rootVC=%@，已 makeKeyAndVisible",
                        session.bundleID, storyboardName, NSStringFromClass([rootVC class])] UTF8String]);
        return YES;
    } @catch (NSException *exception) {
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ storyboard 建窗抛异常（%@），走 scene 路",
                        session.bundleID, exception.reason] UTF8String]);
        return NO;
    }
}

- (BOOL)activateGuestWithContext:(SBGuestMainHookContext *)context
              principalClassName:(nullable NSString *)principalClassName
               delegateClassName:(nullable NSString *)delegateClassName
                           error:(NSError **)error {
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        __block NSError *blockError = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self activateGuestWithContext:context
                                 principalClassName:principalClassName
                                  delegateClassName:delegateClassName
                                              error:&blockError];
        });
        if (error) {
            *error = blockError;
        }
        return result;
    }
    if (self.sessions[context.bundleID]) {
        // 首次加载不应撞上已有会话——点图标应先走恢复路径；撞上了是接线错，干净失败。
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorGuestLoadFailed, @"加载客 App",
                                            @"该应用已在后台，请从桌面恢复进入",
                                            @"请重试");
        }
        return NO;
    }
    // 另一客在前台：先让它回后台（藏窗、换出 delegate），再上新客。
    SBGuestSession *current = [self currentSession];
    if (current && current.active && ![current.bundleID isEqualToString:context.bundleID]) {
        [self backgroundCurrentGuest];
    }
    [self saveHostStateIfNeeded];
    UIApplication *app = [UIApplication sharedApplication];

    // principal class：nil 或 UIApplication 是常态；自定义 UIApplication 子类
    // 换不了单例类（宿主的已在跑），记一行警告继续——delegate 交换仍生效。
    if (principalClassName.length > 0 &&
        ![principalClassName isEqualToString:@"UIApplication"]) {
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ principal class 是 %@（非默认 UIApplication），单例类无法替换，仍用宿主的 UIApplication 实例",
                        context.bundleID, principalClassName] UTF8String]);
    }
    NSString *resolvedDelegateClassName = delegateClassName;
    if (resolvedDelegateClassName.length == 0) {
        // 0.2.36：main 没传 delegate 类时，按名探测真 AppDelegate（模块名取
        // 客可执行名）——0.2.35 真机 MediaStormCamera 的 main 传 delegate=nil
        // （SwiftUI lifecycle 调 UIApplicationMain(nil, nil)，见 183528 日志
        // principal=(nil) delegate=(nil)），旧回退直接拿 UISceneDelegateClassName
        // （MediaStormCamera.SceneDelegate）当 app.delegate 装上；其 willConnect
        // 里 `delegate as! AppDelegate` 一类强转必 trap（死在 willConnect 内的
        // 头号嫌疑）。探测不到时不再回退到 scene delegate 类（见下一块），宁可干净失败。
        NSString *moduleName = [context.guestExecPath lastPathComponent];
        NSString *appDelegateName = [NSString stringWithFormat:@"%@.AppDelegate", moduleName];
        if (NSClassFromString(appDelegateName)) {
            resolvedDelegateClassName = appDelegateName;
            SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ main 未传 delegate 类，按名探测到真 AppDelegate（%@），不用 scene delegate 充数",
                            context.bundleID, appDelegateName] UTF8String]);
        }
    }
    if (resolvedDelegateClassName.length == 0) {
        // 0.2.36：按名也探测不到真 AppDelegate时，再试 ObjC 风格的裸类名
        // AppDelegate。仍没有就干净失败——绝不再回退到 plist 的 scene delegate
        // 类：Flutter 调查（OmoFun 反汇编，见 build log 0.2.36 节）证实，把
        // Runner.SceneDelegate 当 app.delegate 装上是致命的：SceneDelegate
        // 不实现 didFinishLaunching，真 AppDelegate 从未实例化、插件从未注册、
        // launch engine 从未建；其 willConnect 里的 `as? AppDelegate` 也得
        // nil。装错 delegate 只会静默死或黑屏，不如干净失败写明原因。
        if (NSClassFromString(@"AppDelegate")) {
            resolvedDelegateClassName = @"AppDelegate";
            SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ main 未传 delegate 类，按名探测到裸 AppDelegate 类",
                            context.bundleID] UTF8String]);
        } else {
            NSString *moduleName = [context.guestExecPath lastPathComponent];
            SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ main 未传 delegate 类，按名探测不到真 AppDelegate（%@.AppDelegate / AppDelegate 均无），不用 scene delegate 类充 app.delegate，干净失败",
                            context.bundleID, moduleName] UTF8String]);
        }
    }
    Class delegateClass = resolvedDelegateClassName.length > 0
        ? NSClassFromString(resolvedDelegateClassName) : Nil;
    if (!delegateClass) {
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorGuestLoadFailed, @"加载客 App",
                                            [NSString stringWithFormat:@"找不到客 AppDelegate 类（%@）", resolvedDelegateClassName ?: @"未指定"],
                                            @"该客 App 可能与当前系统版本不兼容");
        }
        return NO;
    }
    id guestDelegate = [[delegateClass alloc] init];
    if (!guestDelegate) {
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorGuestLoadFailed, @"加载客 App",
                                            @"客 AppDelegate 创建失败",
                                            @"请重试，或重新导入该应用");
        }
        return NO;
    }

    SBGuestSession *session = [[SBGuestSession alloc] init];
    session.bundleID = context.bundleID;
    session.containerUUID = context.containerUUID;
    session.diskDirectoryName = context.diskDirectoryName;
    session.keychainGroup = context.keychainGroup;
    session.guestAppPath = context.guestAppPath;
    session.guestExecPath = context.guestExecPath;
    session.containerPath = context.containerPath;
    session.guestHandle = context.guestHandle;
    session.guestBundle = context.guestBundle;
    session.guestAppDelegate = guestDelegate;
    session.guestScene = self.hostScene;
    session.windowsBeforeActivation = [NSSet setWithArray:app.windows];
    session.loaded = YES;
    session.active = NO; // 窗口出现后 completeActivation 才置 YES。
    self.sessions[context.bundleID] = session;
    self.currentBundleID = context.bundleID;

    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 拦截 UIApplicationMain，换上客 delegate %@（宿主 delegate 已保存）",
                    context.bundleID, resolvedDelegateClassName] UTF8String]);
    app.delegate = guestDelegate;
    if ([guestDelegate respondsToSelector:@selector(application:didFinishLaunchingWithOptions:)]) {
        @try {
            [guestDelegate application:app didFinishLaunchingWithOptions:nil];
        } @catch (NSException *exception) {
            SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ didFinishLaunching 抛异常（%@），恢复宿主",
                            context.bundleID, exception.reason] UTF8String]);
            [self.sessions removeObjectForKey:context.bundleID];
            self.currentBundleID = nil;
            [self restoreHostUI];
            [SBGuestBootstrap restoreHostContext];
            if (error) {
                *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorGuestLoadFailed, @"加载客 App",
                                                [NSString stringWithFormat:@"客 App 启动失败（%@）", exception.reason ?: @"未知原因"],
                                                @"请重试，或重新导入该应用");
            }
            return NO;
        }
    } else {
        // 0.2.36：不实现 didFinishLaunching 就记一行——之前静默跳过，下份
        // 日志无法区分“没调”与“调了无事发生”（0.2.35 真机两 Flutter 客装
        // 的是 SceneDelegate，本来就不实现它，却无任何痕迹）。
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ delegate（%@）未实现 didFinishLaunching，跳过",
                        context.bundleID, resolvedDelegateClassName] UTF8String]);
    }
    // 0.2.36：Flutter 客建窗（#3/#4）——didFinishLaunching 只做插件注册，
    // 不建窗；窗是 UIKit 加载 storyboard 建的。尚无窗且客有 storyboard 时
    // 在这里同步建好，随后的 findGuestWindow 即命中，直接完成激活。
    [self buildGuestWindowFromStoryboardForSession:session];
    // pre-scene 客／storyboard 客：didFinishLaunching 或 storyboard 里已建窗，同步完成。
    if ([self findGuestWindowForSession:session]) {
        [self completeActivationForSession:session];
        return YES;
    }
    // scene 客：先试系统路（UIKit 经 delegate 问配置、请求 scene session），
    // 0.4 秒后补查，无窗则手动 willConnect。宿主 MultipleScenes=false，
    // iPhone 上系统路大概率不建新 scene，手动路是主路。
    [app requestSceneSessionActivation:nil
                          userActivity:nil
                               options:nil
                          errorHandler:^(NSError *requestError) {
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 请求 scene session 失败（%@），等 0.4 秒补查走手动路",
                        context.bundleID, requestError.localizedDescription] UTF8String]);
    }];
    __weak SBGuestSession *weakSession = session;
    NSString *checkBundleID = session.bundleID;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(SBGuestSceneSystemPathWaitSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SBGuestSession *strongSession = weakSession;
        if (strongSession) {
            [self checkSceneSystemPathForSession:strongSession];
        } else {
            // 0.2.33：会话在 0.4 秒内被释放——之前这里静默无操作，下份日志会
            // 误读成“死在替身返回到补查之间”；记一行区分。
            SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 0.4 秒补查：会话已释放，不补查",
                            checkBundleID] UTF8String]);
        }
    });
    return YES;
}

#pragma mark - SwiftUI 嵌客激活（0.2.28）

- (BOOL)activateSwiftUIGuestWithContext:(SBGuestMainHookContext *)context
                      hostingController:(UIViewController *)hostingController
                            appInstance:(nullable id)appInstance
                            appDelegate:(nullable id)appDelegate
                                  error:(NSError **)error {
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        __block NSError *blockError = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self activateSwiftUIGuestWithContext:context
                                         hostingController:hostingController
                                               appInstance:appInstance
                                               appDelegate:appDelegate
                                                     error:&blockError];
        });
        if (error) {
            *error = blockError;
        }
        return result;
    }
    if (!hostingController) {
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorGuestLoadFailed, @"加载客 App",
                                            @"SwiftUI 嵌客未建出 UIHostingController",
                                            @"请重试，或重新导入该应用");
        }
        return NO;
    }
    if (self.sessions[context.bundleID]) {
        // 首次加载不应撞上已有会话——点图标应先走恢复路径；撞上了是接线错，干净失败。
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorGuestLoadFailed, @"加载客 App",
                                            @"该应用已在后台，请从桌面恢复进入",
                                            @"请重试");
        }
        return NO;
    }
    // 另一客在前台：先让它回后台（藏窗、换出 delegate），再上新客。
    SBGuestSession *current = [self currentSession];
    if (current && current.active && ![current.bundleID isEqualToString:context.bundleID]) {
        [self backgroundCurrentGuest];
    }
    [self saveHostStateIfNeeded];
    UIApplication *app = [UIApplication sharedApplication];

    SBGuestSession *session = [[SBGuestSession alloc] init];
    session.bundleID = context.bundleID;
    session.containerUUID = context.containerUUID;
    session.diskDirectoryName = context.diskDirectoryName;
    session.keychainGroup = context.keychainGroup;
    session.guestAppPath = context.guestAppPath;
    session.guestExecPath = context.guestExecPath;
    session.containerPath = context.containerPath;
    session.guestHandle = context.guestHandle;
    session.guestBundle = context.guestBundle;
    session.guestSwiftUIApp = appInstance;
    session.guestHostingController = hostingController;
    if (appDelegate) {
        session.guestAppDelegate = appDelegate;
    }
    session.guestScene = self.hostScene;
    session.windowsBeforeActivation = [NSSet setWithArray:app.windows];
    session.loaded = YES;
    session.active = NO; // 窗口建好后才置 YES。
    self.sessions[context.bundleID] = session;
    self.currentBundleID = context.bundleID;

    // adaptor delegate：有才换上并调 didFinishLaunching（无 adaptor 时不碰
    // app.delegate——宿主 delegate 必须留着，置 nil 会丢）。
    if (appDelegate) {
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客（SwiftUI）：%@ 有 @UIApplicationDelegateAdaptor，换上客 delegate %@",
                        context.bundleID, NSStringFromClass([appDelegate class])] UTF8String]);
        app.delegate = appDelegate;
        if ([appDelegate respondsToSelector:@selector(application:didFinishLaunchingWithOptions:)]) {
            @try {
                [appDelegate application:app didFinishLaunchingWithOptions:nil];
            } @catch (NSException *exception) {
                SBDiagLogLine([[NSString stringWithFormat:@"进程内进客（SwiftUI）：%@ didFinishLaunching 抛异常（%@），恢复宿主",
                                context.bundleID, exception.reason] UTF8String]);
                [self.sessions removeObjectForKey:context.bundleID];
                self.currentBundleID = nil;
                [self restoreHostUI];
                [SBGuestBootstrap restoreHostContext];
                if (error) {
                    *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorGuestLoadFailed, @"加载客 App",
                                                    [NSString stringWithFormat:@"客 App 启动失败（%@）", exception.reason ?: @"未知原因"],
                                                    @"请重试，或重新导入该应用");
                }
                return NO;
            }
        }
    } else {
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客（SwiftUI）：%@ 无 @UIApplicationDelegateAdaptor，不换 app.delegate",
                        context.bundleID] UTF8String]);
    }
    // 在宿主 scene 上建客窗口（rootViewController=hosting），与 UIKit 客
    // 的窗口/scene 一致处理（侧滑回宿主藏窗、多客后台保留都复用同一套）。
    UIWindowScene *scene = self.hostScene;
    if (!scene) {
        [self.sessions removeObjectForKey:context.bundleID];
        self.currentBundleID = nil;
        [self restoreHostUI];
        [SBGuestBootstrap restoreHostContext];
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorGuestLoadFailed, @"加载客 App",
                                            @"找不到宿主 scene，无法为客 App 创建窗口",
                                            @"请重试");
        }
        return NO;
    }
    UIWindow *guestWindow = [[UIWindow alloc] initWithWindowScene:scene];
    guestWindow.rootViewController = hostingController;
    guestWindow.hidden = NO;
    [guestWindow makeKeyAndVisible];
    session.guestWindow = guestWindow;
    session.guestScene = scene;
    session.active = YES;
    self.currentBundleID = context.bundleID;
    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客（SwiftUI）：%@ 已激活（客窗 %@，UIHostingController 根视图）",
                    context.bundleID, NSStringFromCGRect(guestWindow.frame)] UTF8String]);
    // 激活即证明启动成功：记成功、护栏归零（与 UIKit 客 completeActivation 同款）。
    [SBGuestLaunchPreflight noteGuestActivatedInProcessWithBundleID:session.bundleID
                                                      containerUUID:session.containerUUID
                                                  diskDirectoryName:session.diskDirectoryName];
    [[NSNotificationCenter defaultCenter] postNotificationName:SBGuestDidEnterForegroundNotification
                                                        object:nil];
    return YES;
}

#pragma mark - 恢复 / 回后台

- (nullable SBGuestSession *)resumeGuestWithBundleID:(NSString *)bundleID {
    if (![NSThread isMainThread]) {
        __block SBGuestSession *result = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self resumeGuestWithBundleID:bundleID];
        });
        return result;
    }
    self.lastResumeError = nil;
    SBGuestSession *session = self.sessions[bundleID];
    if (!session || !session.loaded) {
        return nil; // 未加载过——调用方走首次加载（lastResumeError 为 nil 以示区分）。
    }
    if (session.active && [self.currentBundleID isEqualToString:bundleID]) {
        return session; // 已在前台，无事可做。
    }
    SBGuestSession *current = [self currentSession];
    if (current && current.active && ![current.bundleID isEqualToString:bundleID]) {
        [self backgroundCurrentGuest];
    }
    // 重上客上下文（Bundle 伪装/可执行路径/进程身份/HOME/env）：hook 件按
    // 环境变量与当前 HOME 工作，恢复时必须重设为该客的值。
    // applyGuestContext 返回 BOOL、Bundle 由 guestBundleOut 回填（0.2.27
    // fixup 5：此前调用方错当成返回 NSBundle 且漏 guestBundleOut，
    // run 44733218725 红于此）。
    NSError *contextError = nil;
    NSBundle *guestBundle = nil;
    BOOL contextOK = [SBGuestBootstrap applyGuestContextForBundleID:bundleID
                                                       guestAppPath:session.guestAppPath
                                                      guestExecPath:session.guestExecPath
                                                      containerPath:session.containerPath
                                                      keychainGroup:session.keychainGroup
                                                              error:&contextError
                                                   guestBundleOut:&guestBundle];
    if (!contextOK) {
        self.lastResumeError = contextError;
        return nil;
    }
    session.guestBundle = guestBundle;
    [self saveHostStateIfNeeded];
    UIApplication *app = [UIApplication sharedApplication];
    // 0.2.28：SwiftUI 嵌客无 adaptor 时 guestAppDelegate 为 nil，置 nil 会
    // 丢宿主 delegate；只在非空时换。UIKit 客恒有 delegate，行为不变。
    if (session.guestAppDelegate) {
        app.delegate = session.guestAppDelegate;
    }
    if (session.guestSceneDelegate && session.guestScene) {
        session.guestScene.delegate = session.guestSceneDelegate;
    }
    session.guestWindow.hidden = NO;
    [session.guestWindow makeKeyAndVisible];
    session.active = YES;
    self.currentBundleID = bundleID;
    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 已恢复（后台→前台，未重 dlopen/未重跑 main）",
                    bundleID] UTF8String]);
    [[NSNotificationCenter defaultCenter] postNotificationName:SBGuestDidEnterForegroundNotification
                                                        object:nil];
    return session;
}

- (void)backgroundCurrentGuest {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self backgroundCurrentGuest];
        });
        return;
    }
    SBGuestSession *session = [self currentSession];
    if (!session || !session.active) {
        return;
    }
    session.guestWindow.hidden = YES;
    session.active = NO;
    self.currentBundleID = nil;
    [self restoreHostUI];
    [SBGuestBootstrap restoreHostContext];
    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 已回后台（会话保留：delegate/窗口/scene/HOME 全在）",
                    session.bundleID] UTF8String]);
    [[NSNotificationCenter defaultCenter] postNotificationName:SBGuestDidEnterBackgroundNotification
                                                        object:nil];
}

#pragma mark - 通知

- (void)handleReturnToHostRequested:(NSNotification *)note {
    // 0.2.36：去重——侧滑/横杠一次手势发 6–7 次通知（0.2.35 真机：84–91 毫秒内
    // 连发 6–7 次）。第一次已让客回后台（currentBundleID 已空、session.active
    // 已 NO），之后的全是空操作还各记一行。无前台客时直接忽略，不记日志。
    // 状态去重而非时间节流：回宿主→再进客→再回宿主可以发生在 0.5 秒内，
    // 时间窗会误吞第二次合法请求；前台客状态是唯一正确的判据。
    SBGuestSession *current = [self currentSession];
    if (!current || !current.active) {
        return;
    }
    // 浮层（注入件）发的回宿主请求：当前客回后台，会话保留、收据不清除。
    SBDiagLogLine([@"进程内进客：收到回宿主请求（侧滑/横杠），当前客回后台" UTF8String]);
    [self backgroundCurrentGuest];
}

@end
