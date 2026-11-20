// SBHomeBarOverlay.m — 客 App 内底部横杠 + 左下角侧滑：
//   上滑 ≥32pt 或快滑（速度 >140pt/s）→ 回宿主（0.2.27：发通知，不再 exit(0)）；
//   左下角左边缘右滑 ≥40pt 或速度 >300pt/s → 回宿主（0.2.27 新增，MJ 要求）；
//   按住 0.42s / 双击 / 上滑后停顿 0.35s → toast「切换器 v1 未提供」
//   （v1 不做切换器，只提示，不静默吞手势）。
// 实现：一只高层级透明 UIWindow，只在底部 28pt 的横杠条与左下角 16×160pt 的
// 左边缘区上接手势，其余区域 hitTest 返回 nil，触摸原样透给客 App。
// 回宿主 = 发通知给宿主会话管理器（当前客回后台，会话保留、收据不清除），
// 客退出回宿主 UI 仍由客 main 返回/收据生命周期管，不在这里清标记、
// 更不退出进程（0.2.27 前这里是清标记 + exit(0)，进程内模型下那会杀掉宿主
// 与全部后台客）。
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>

// 与契约一致：横杠数值。横杠条高 28pt，与壳子回主屏幕区（SealboxApp.swift
// homeSwipeZone，28pt）一致：0.1.0 的 44pt 会盖住客 App 底部 28pt 以上
// 区域的手势，改 28pt 后只占底部 28pt，与壳子同口径。
// 不拦截 28pt 以上区域的手势：容器视图 SBHomeBarPassthroughView 的 hitTest
// 只在触点落在 barView 内时返回 barView，其余一律返回 nil、原样透给客 App。
static const CGFloat SBHomeBarHeight = 28.0;      // 横杠条可点高度
static const CGFloat SBHomeBarSwipeDistance = 32.0; // 上滑回桌面的距离阈值（pt）
static const CGFloat SBHomeBarFastSwipeVelocity = 140.0; // 快滑速度阈值（pt/s）
static const NSTimeInterval SBHomeBarLongPressSeconds = 0.42; // 按住阈值
static const NSTimeInterval SBHomeBarPauseSeconds = 0.35;     // 上滑停顿阈值
// 0.2.27 左下角侧滑回宿主：左边缘 16pt 宽 × 底部 160pt 高的区，右滑触发。
// home indicator 是底边（上滑），左边缘可用；区只占极左 16pt，客底部 UI
// 几乎不落在该条带内（落在其中的轻点会被吞掉——已知取舍，见 build log）。
static const CGFloat SBHomeBarLeftEdgeZoneWidth = 16.0;
static const CGFloat SBHomeBarLeftEdgeZoneHeight = 160.0;
static const CGFloat SBHomeBarLeftEdgeSwipeDistance = 40.0; // 右滑触发距离（pt）
static const CGFloat SBHomeBarLeftEdgeFastSwipeVelocity = 300.0; // 右滑快滑速度（pt/s）

// 通知名（与宿主 SBGuestSessionManager.h 里的同名常量必须一致，原型核对）。
static NSString * const SBGuestReturnToHostRequestedNotification = @"SBGuestReturnToHostRequested";
static NSString * const SBGuestDidEnterBackgroundNotification = @"SBGuestDidEnterBackground";
static NSString * const SBGuestDidEnterForegroundNotification = @"SBGuestDidEnterForeground";

static UIWindow *g_overlayWindow = nil;
static UILabel *g_toastLabel = nil;
static NSUInteger g_toastGeneration = 0;
static BOOL g_overlayInstalled = NO;

/// 除横杠条与左边缘区外不拦截触摸的容器视图。
@interface SBHomeBarPassthroughView : UIView
@property (nonatomic, weak, nullable) UIView *barView;
@property (nonatomic, weak, nullable) UIView *leftEdgeZone;
@end

@implementation SBHomeBarPassthroughView

- (nullable UIView *)hitTest:(CGPoint)point withEvent:(nullable UIEvent *)event {
    if (self.barView) {
        CGPoint pointInBar = [self convertPoint:point toView:self.barView];
        if ([self.barView pointInside:pointInBar withEvent:event]) {
            return [self.barView hitTest:pointInBar withEvent:event];
        }
    }
    if (self.leftEdgeZone) {
        CGPoint pointInZone = [self convertPoint:point toView:self.leftEdgeZone];
        if ([self.leftEdgeZone pointInside:pointInZone withEvent:event]) {
            return [self.leftEdgeZone hitTest:pointInZone withEvent:event];
        }
    }
    return nil;
}

@end

#pragma mark - Toast

static void SBHomeBarShowToast(NSString *text) {
    if (!g_overlayWindow) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_toastLabel) {
            UILabel *label = [[UILabel alloc] init];
            label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.75];
            label.textColor = [UIColor whiteColor];
            label.font = [UIFont systemFontOfSize:14.0];
            label.textAlignment = NSTextAlignmentCenter;
            label.numberOfLines = 1;
            label.layer.cornerRadius = 17.0;
            label.layer.masksToBounds = YES;
            label.alpha = 0.0;
            [g_overlayWindow addSubview:label];
            g_toastLabel = label;
        }
        g_toastLabel.text = text;
        CGSize textSize = [text sizeWithAttributes:@{ NSFontAttributeName: g_toastLabel.font }];
        CGFloat width = MIN(textSize.width + 32.0, CGRectGetWidth(g_overlayWindow.bounds) - 48.0);
        g_toastLabel.frame = CGRectMake((CGRectGetWidth(g_overlayWindow.bounds) - width) / 2.0,
                                        CGRectGetHeight(g_overlayWindow.bounds) - 120.0,
                                        width, 34.0);
        [g_overlayWindow bringSubviewToFront:g_toastLabel];
        NSUInteger generation = ++g_toastGeneration;
        [UIView animateWithDuration:0.2 animations:^{
            g_toastLabel.alpha = 1.0;
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation != g_toastGeneration) {
                return;
            }
            [UIView animateWithDuration:0.3 animations:^{
                g_toastLabel.alpha = 0.0;
            }];
        });
    });
}

#pragma mark - 回桌面

/// 回桌面（0.2.27 进程内）：发通知给宿主会话管理器——当前客回后台
///（会话保留、收据不清除），宿主界面恢复。不再清启动标记、不再退出进程。
static void SBHomeBarGoHome(void) {
    [[NSNotificationCenter defaultCenter] postNotificationName:SBGuestReturnToHostRequestedNotification
                                                        object:nil];
}

/// 浮层随客藏/显：客回后台时藏起（不悬在宿主界面上），客进前台时显出。
static void SBHomeBarSetOverlayHidden(BOOL hidden) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SBHomeBarSetOverlayHidden(hidden);
        });
        return;
    }
    if (g_overlayWindow) {
        g_overlayWindow.hidden = hidden;
    }
}

#pragma mark - 手势处理

/// 横杠条的事件处理（target 用 NSObject 挂手势，避免在分类里加状态）。
@interface SBHomeBarGestureHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, assign) BOOL panActive;
@property (nonatomic, assign) CGFloat lastPanTranslationY;
@property (nonatomic, assign) NSTimeInterval lastPanMoveTime;
@property (nonatomic, assign) NSUInteger pauseGeneration;
@property (nonatomic, assign) BOOL pauseToastShown;
@end

@implementation SBHomeBarGestureHandler

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            self.panActive = YES;
            self.pauseToastShown = NO;
            self.lastPanTranslationY = 0.0;
            self.lastPanMoveTime = CACurrentMediaTime();
            [self schedulePauseCheck];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGFloat translationY = [pan translationInView:pan.view].y;
            CGFloat velocityY = [pan velocityInView:pan.view].y;
            self.lastPanTranslationY = translationY;
            self.lastPanMoveTime = CACurrentMediaTime();
            if (translationY <= -SBHomeBarSwipeDistance || velocityY <= -SBHomeBarFastSwipeVelocity) {
                self.panActive = NO;
                self.pauseGeneration++; // 取消待发的停顿检查
                SBHomeBarGoHome();
                return;
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            self.panActive = NO;
            self.pauseGeneration++; // 取消待发的停顿检查
            break;
        }
        default:
            break;
    }
}

/// 上滑停顿检查：手指上滑后 0.35s 没再动，且停在 -8pt 以上，就 toast 一次。
- (void)schedulePauseCheck {
    NSUInteger generation = ++self.pauseGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SBHomeBarPauseSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self.pauseGeneration || !self.panActive || self.pauseToastShown) {
            return;
        }
        NSTimeInterval idleTime = CACurrentMediaTime() - self.lastPanMoveTime;
        if (idleTime >= SBHomeBarPauseSeconds - 0.05 && self.lastPanTranslationY < -8.0) {
            self.pauseToastShown = YES;
            SBHomeBarShowToast(@"切换器 v1 未提供");
        }
    });
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)press {
    if (press.state == UIGestureRecognizerStateBegan) {
        SBHomeBarShowToast(@"切换器 v1 未提供");
    }
}

/// 左下角左边缘右滑 → 回宿主（0.2.27，MJ 要求）。只在右滑够远/够快时触发，
// 轻点与竖滑不触发；触发后浮层随客藏起，后续手势不再进这里。
- (void)handleLeftEdgePan:(UIScreenEdgePanGestureRecognizer *)pan {
    if (pan.state != UIGestureRecognizerStateChanged &&
        pan.state != UIGestureRecognizerStateEnded) {
        return;
    }
    CGFloat translationX = [pan translationInView:pan.view].x;
    CGFloat velocityX = [pan velocityInView:pan.view].x;
    if (translationX >= SBHomeBarLeftEdgeSwipeDistance ||
        velocityX >= SBHomeBarLeftEdgeFastSwipeVelocity) {
        SBHomeBarGoHome();
    }
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)tap {
    SBHomeBarShowToast(@"切换器 v1 未提供");
}

@end

#pragma mark - 横杠搭建

static void SBHomeBarEnsureOverlay(void) {
    if (g_overlayWindow) {
        // 已建好但还没挂上 scene（建时 keyWindow 不在）：补挂一次。
        if (!g_overlayWindow.windowScene) {
            g_overlayWindow.windowScene = [UIApplication sharedApplication].keyWindow.windowScene;
        }
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SBHomeBarEnsureOverlay();
        });
        return;
    }
    UIScreen *screen = [UIScreen mainScreen];
    UIWindow *window = [[UIWindow alloc] initWithFrame:screen.bounds];
    window.windowLevel = UIWindowLevelStatusBar + 100.0;
    window.backgroundColor = [UIColor clearColor];
    // 与客窗同 scene 才能叠在客窗上面（客窗在共享的宿主 scene 里）。
    window.windowScene = [UIApplication sharedApplication].keyWindow.windowScene;
    window.hidden = NO;

    SBHomeBarPassthroughView *container = [[SBHomeBarPassthroughView alloc] initWithFrame:window.bounds];
    container.backgroundColor = [UIColor clearColor];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIView *barView = [[UIView alloc] initWithFrame:CGRectMake(0.0,
                                                                CGRectGetHeight(window.bounds) - SBHomeBarHeight,
                                                                CGRectGetWidth(window.bounds),
                                                                SBHomeBarHeight)];
    barView.backgroundColor = [UIColor clearColor];
    barView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;

    // 横杠视觉：居中一粒圆角短横，与系统 Home Indicator 同款位置。
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake((CGRectGetWidth(barView.bounds) - 134.0) / 2.0,
                                                            SBHomeBarHeight - 5.0 - 8.0,
                                                            134.0, 5.0)];
    pill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    pill.layer.cornerRadius = 2.5;
    pill.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [barView addSubview:pill];

    SBHomeBarGestureHandler *handler = [[SBHomeBarGestureHandler alloc] init];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:handler
                                                                            action:@selector(handlePan:)];
    pan.delegate = handler;
    [barView addGestureRecognizer:pan];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:handler
                                                                                             action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = SBHomeBarLongPressSeconds;
    longPress.delegate = handler;
    [barView addGestureRecognizer:longPress];

    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:handler
                                                                                action:@selector(handleDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    doubleTap.delegate = handler;
    [barView addGestureRecognizer:doubleTap];

    // 横杠条持有 handler（手势的 target 是弱引用，靠关联对象保活）。
    static const char SBHomeBarHandlerKey;
    objc_setAssociatedObject(barView, &SBHomeBarHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 0.2.27 左下角左边缘区（16×160pt）：只接左边缘右滑回宿主，其余触摸透过。
    UIView *leftEdgeZone = [[UIView alloc] initWithFrame:CGRectMake(0.0,
                                                                     CGRectGetHeight(window.bounds) - SBHomeBarLeftEdgeZoneHeight,
                                                                     SBHomeBarLeftEdgeZoneWidth,
                                                                     SBHomeBarLeftEdgeZoneHeight)];
    leftEdgeZone.backgroundColor = [UIColor clearColor];
    leftEdgeZone.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleTopMargin;
    UIScreenEdgePanGestureRecognizer *edgePan = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:handler
                                                                                                   action:@selector(handleLeftEdgePan:)];
    edgePan.edges = UIRectEdgeLeft;
    edgePan.delegate = handler;
    [leftEdgeZone addGestureRecognizer:edgePan];

    container.barView = barView;
    container.leftEdgeZone = leftEdgeZone;
    [container addSubview:barView];
    [container addSubview:leftEdgeZone];

    UIViewController *rootViewController = [[UIViewController alloc] init];
    rootViewController.view = container;
    window.rootViewController = rootViewController;

    g_overlayWindow = window;
}

void SBHomeBarOverlayInstall(void) {
    if (g_overlayInstalled) {
        return;
    }
    g_overlayInstalled = YES;
    // 客 App 的 keyWindow 可能在 constructor 时还没建好：立即试一次，
    // 再在每次变活跃时补一次（幂等，建好后直接返回）。
    dispatch_async(dispatch_get_main_queue(), ^{
        SBHomeBarEnsureOverlay();
    });
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        SBHomeBarEnsureOverlay();
    }];
    // 0.2.27：浮层随客藏/显——客回后台时藏起（不悬在宿主界面上），客进前台时显出。
    [[NSNotificationCenter defaultCenter] addObserverForName:SBGuestDidEnterBackgroundNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        SBHomeBarSetOverlayHidden(YES);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:SBGuestDidEnterForegroundNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        SBHomeBarSetOverlayHidden(NO);
    }];
}
