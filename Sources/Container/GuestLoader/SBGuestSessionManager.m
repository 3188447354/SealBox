// SBGuestSessionManager.m — 客 App 后台会话注册表（0.2.27 进程内进客）。
//
// 状态：
//   loaded=YES, guestWindow=nil            → 正在激活（异步 scene 驱动待完成）
//   loaded=YES, active=YES, guestWindow!=nil → 前台运行
//   loaded=YES, active=NO,  guestWindow!=nil → 后台保留（再点即恢复）
// 会话是内存态：进程被杀后注册表即失，下次启动 guest-loaded 收据由路由静默清除，
// 进宿主界面（不跨进程恢复）。
#import "SBGuestSessionManager.h"

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
    [self.sessions removeObjectForKey:session.bundleID];
    if ([self.currentBundleID isEqualToString:session.bundleID]) {
        self.currentBundleID = nil;
    }
    [self restoreHostUI];
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
- (void)driveSceneManuallyForSession:(SBGuestSession *)session {
    if (session.guestWindow) {
        return;
    }
    UIWindowScene *scene = self.hostScene;
    if (!scene) {
        [self failActivationForSession:session message:@"找不到宿主 scene，无法为客 App 创建窗口"];
        return;
    }
    UISceneSession *sceneSession = scene.session;
    // 空 options（alloc/init 造，非 nil）：Swift 写的 scene delegate 若强解
    // options 不会崩；读 userActivities/URL 上下文只会拿到空值。
    UISceneConnectionOptions *options = [[UISceneConnectionOptions alloc] init];
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
    id sceneDelegate = [[config.delegateClass alloc] init];
    if (!sceneDelegate) {
        [self failActivationForSession:session message:@"客 scene delegate 创建失败"];
        return;
    }
    session.guestSceneDelegate = sceneDelegate;
    scene.delegate = sceneDelegate;
    @try {
        if ([sceneDelegate respondsToSelector:@selector(scene:willConnectToSession:options:)]) {
            [sceneDelegate scene:scene willConnectToSession:sceneSession options:options];
        }
    } @catch (NSException *exception) {
        SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ scene willConnect 抛异常（%@）",
                        session.bundleID, exception.reason] UTF8String]);
        [self failActivationForSession:session
                               message:[NSString stringWithFormat:@"客 App 创建窗口失败（%@）", exception.reason ?: @"未知原因"]];
        return;
    }
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
        return;
    }
    if (session.guestWindow) {
        return;
    }
    if ([self findGuestWindowForSession:session]) {
        [self completeActivationForSession:session];
        return;
    }
    SBDiagLogLine([[NSString stringWithFormat:@"进程内进客：%@ 系统 scene 路 0.4 秒无窗，走手动 willConnect",
                    session.bundleID] UTF8String]);
    [self driveSceneManuallyForSession:session];
}

#pragma mark - 激活

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
        // main 没传 delegate 类：从客 Info.plist 的 scene 配置里取。
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:
            [context.guestAppPath stringByAppendingPathComponent:@"Info.plist"]];
        NSDictionary *manifest = plist[@"UIApplicationSceneManifest"];
        NSDictionary *configsByRole = manifest[@"UISceneConfigurations"];
        NSArray *configs = configsByRole[@"UIWindowSceneSessionRoleApplication"];
        if ([configs isKindOfClass:[NSArray class]] && configs.count > 0) {
            resolvedDelegateClassName = configs[0][@"UISceneDelegateClassName"];
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
    }
    // pre-scene 客：delegate 在 didFinishLaunching 里已建窗，同步完成。
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(SBGuestSceneSystemPathWaitSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SBGuestSession *strongSession = weakSession;
        if (strongSession) {
            [self checkSceneSystemPathForSession:strongSession];
        }
    });
    return YES;
}

#pragma mark - 恢复 / 回后台

- (BOOL)resumeGuestWithBundleID:(NSString *)bundleID error:(NSError **)error {
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        __block NSError *blockError = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self resumeGuestWithBundleID:bundleID error:&blockError];
        });
        if (error) {
            *error = blockError;
        }
        return result;
    }
    SBGuestSession *session = self.sessions[bundleID];
    if (!session || !session.loaded) {
        return NO; // 未加载过——调用方走首次加载。
    }
    if (session.active && [self.currentBundleID isEqualToString:bundleID]) {
        return YES; // 已在前台，无事可做。
    }
    SBGuestSession *current = [self currentSession];
    if (current && current.active && ![current.bundleID isEqualToString:bundleID]) {
        [self backgroundCurrentGuest];
    }
    // 重上客上下文（Bundle 伪装/可执行路径/进程身份/HOME/env）：hook 件按
    // 环境变量与当前 HOME 工作，恢复时必须重设为该客的值。
    NSError *contextError = nil;
    NSBundle *guestBundle = [SBGuestBootstrap applyGuestContextForBundleID:bundleID
                                                              guestAppPath:session.guestAppPath
                                                             guestExecPath:session.guestExecPath
                                                             containerPath:session.containerPath
                                                             keychainGroup:session.keychainGroup
                                                                     error:&contextError];
    if (!guestBundle) {
        if (error) {
            *error = contextError;
        }
        return NO;
    }
    session.guestBundle = guestBundle;
    [self saveHostStateIfNeeded];
    UIApplication *app = [UIApplication sharedApplication];
    app.delegate = session.guestAppDelegate;
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
    return YES;
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
    // 浮层（注入件）发的回宿主请求：当前客回后台，会话保留、收据不清除。
    SBDiagLogLine(@"进程内进客：收到回宿主请求（侧滑/横杠），当前客回后台");
    [self backgroundCurrentGuest];
}

@end
