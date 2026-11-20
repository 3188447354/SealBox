// SBGuestSessionManager.h — 客 App 后台会话注册表（0.2.27 进程内进客）。
//
// 一客一个会话，按 bundleID 存：dlopen 句柄（永不 dlclose）、AppDelegate、
// scene delegate、窗口/scene、已加载标志、HOME/容器。侧滑回桌面时不销毁客——
// 只藏起窗口/scene、换回宿主 delegate 与宿主窗口；再点已开过的客走恢复路径
// （不重新 dlopen、不重新跑 main、不重调 didFinishLaunching）。
//
// 通知（名字串与注入件 SBHomeBarOverlay.m 里的同名字串必须一致，原型核对）：
//   SBGuestReturnToHostRequested — 客内侧滑/横杠上滑 → 回宿主（会话保留）
//   SBGuestDidEnterBackground    — 客已回后台（浮层窗口藏起）
//   SBGuestDidEnterForeground    — 客已进前台（浮层窗口显出）
//   SBGuestActivationFailed      — 异步激活失败（userInfo 带中文原因）
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const SBGuestReturnToHostRequestedNotification;
extern NSString * const SBGuestDidEnterBackgroundNotification;
extern NSString * const SBGuestDidEnterForegroundNotification;
extern NSString * const SBGuestActivationFailedNotification;
extern NSString * const SBGuestActivationFailedMessageKey;

/// 客加载时传给 hook 的上下文（bootstrap 在 dlopen 后、跳 main 前装好；
/// 会话保留它，供恢复时重上客上下文用）。
@interface SBGuestMainHookContext : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *containerUUID;
@property (nonatomic, copy, nullable) NSString *diskDirectoryName;
@property (nonatomic, assign) NSInteger keychainGroup;
@property (nonatomic, copy) NSString *guestAppPath;
@property (nonatomic, copy) NSString *guestExecPath;
@property (nonatomic, copy) NSString *containerPath;
@property (nonatomic, assign) void *guestHandle;
@property (nonatomic, strong, nullable) NSBundle *guestBundle;
@end

/// 一客的后台会话。常驻内存：dlopen 的镜像、delegate、窗口、数据都在进程里，
// 不 dlclose、不销毁。内存代价如实记进 build log；不擅自加“杀后台”UI（MJ 没要）。
@interface SBGuestSession : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *containerUUID;
@property (nonatomic, copy, nullable) NSString *diskDirectoryName;
@property (nonatomic, assign) NSInteger keychainGroup;
@property (nonatomic, copy) NSString *guestAppPath;
@property (nonatomic, copy) NSString *guestExecPath;
@property (nonatomic, copy) NSString *containerPath;
@property (nonatomic, assign) void *guestHandle;
@property (nonatomic, strong, nullable) NSBundle *guestBundle;
@property (nonatomic, strong, nullable) id guestAppDelegate;
@property (nonatomic, strong, nullable) id guestSceneDelegate;
/// 0.2.28：SwiftUI 嵌客的 App 实例（any App，经 SwiftValue 装箱持有；
/// StateObject 等状态要活着，会话持有它）与 UIHostingController。
/// UIKit/Flutter 客这两项为 nil。
@property (nonatomic, strong, nullable) id guestSwiftUIApp;
@property (nonatomic, strong, nullable) UIViewController *guestHostingController;
@property (nonatomic, strong, nullable) UIWindow *guestWindow;
@property (nonatomic, weak, nullable) UIWindowScene *guestScene;
/// 激活前已有的窗口集合（找客窗时排除；浮层窗口在 dlopen 时已建，故在集合内）。
@property (nonatomic, strong, nullable) NSSet<UIWindow *> *windowsBeforeActivation;
@property (nonatomic, assign) BOOL loaded;
@property (nonatomic, assign) BOOL active;
@end

@interface SBGuestSessionManager : NSObject

+ (instancetype)sharedManager;

/// 按 bundleID 取会话（无则 nil）。
- (nullable SBGuestSession *)sessionForBundleID:(NSString *)bundleID;

/// 当前前台客的会话（宿主在前台时 nil）。
- (nullable SBGuestSession *)currentSession;

/// 已加载过则恢复：不 dlopen、不跑 main、不重调 didFinishLaunching；
// 只换回该客的 delegate、激活它的 scene、它的窗口重新成为 key。
// 成功返回该会话；无会话返回 nil（调用方走首次加载）。
// 上下文重上失败返回 nil，同时置 lastResumeError（调用方弹错）。
// 不带 NSError**：带 error 的方法在 Swift 侧桥接成 throws + 非可选返回，
// nil+无错那档会被 Swift 当成抛错，调用方拿不到“无会话落首次加载”
//（0.2.27 fixup 4，run 44731885036 的 Swift 警告实证：
// “comparing non-optional value of type 'SBGuestSession' to 'nil'”）。
- (nullable SBGuestSession *)resumeGuestWithBundleID:(NSString *)bundleID;

/// 最近一次恢复失败的原因（上下文重上失败时置；成功或无会话时为 nil）。
@property (nonatomic, strong, nullable) NSError *lastResumeError;

/// 当前前台客回后台：藏客窗、换出客 delegate、恢复宿主 delegate/窗口/环境；
// 会话保留在注册表里，收据/selected 不清除。无前台客时空操作。
- (void)backgroundCurrentGuest;

/// hook 激活入口（SBGuestMainHook 调）：建会话、保存宿主 delegate/窗口、
// 换上客 delegate、调 didFinishLaunching、驱动 scene 创建。
// pre-scene 客（didFinishLaunching 里建窗）同步完成；scene 客先试
// requestSceneSessionActivation，0.4 秒后无窗则手动 willConnect（异步补查）。
// 同步部分完成后返回 YES（窗口可能稍后出现）；失败返回 NO 且 error 置中文原因。
- (BOOL)activateGuestWithContext:(SBGuestMainHookContext *)context
              principalClassName:(nullable NSString *)principalClassName
               delegateClassName:(nullable NSString *)delegateClassName
                           error:(NSError **)error;

/// SwiftUI 嵌客激活入口（SBSwiftUIEmbed 调）：App 实例与 UIHostingController
// 已由 Swift 侧建好，这里只做会话侧的事——建会话、保存宿主 delegate/窗口、
// 有 adaptor delegate 时才换上并调 didFinishLaunching（无 adaptor 时不碰
// app.delegate）、在宿主 scene 上建客窗口（rootViewController=hosting）、
// 记成功、发进前台通知。同步完成，窗口立即可见；失败返回 NO 且 error 置中文原因。
- (BOOL)activateSwiftUIGuestWithContext:(SBGuestMainHookContext *)context
                      hostingController:(UIViewController *)hostingController
                            appInstance:(nullable id)appInstance
                            appDelegate:(nullable id)appDelegate
                                  error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
