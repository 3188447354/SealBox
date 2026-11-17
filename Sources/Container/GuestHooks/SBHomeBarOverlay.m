// SBHomeBarOverlay.m — 客 App 内底部横杠：
//   上滑 ≥32pt 或快滑（速度 >140pt/s）→ 回桌面（清启动标记 + exit(0)）；
//   按住 0.42s / 双击 / 上滑后停顿 0.35s → toast「切换器 v1 未提供」
//   （v1 不做切换器，只提示，不静默吞手势）。
// 实现：一只高层级透明 UIWindow，只在底部 44pt 的横杠条上接手势，
// 其余区域 hitTest 返回 nil，触摸原样透给客 App。
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>

// 与契约一致：横杠数值
static const CGFloat SBHomeBarHeight = 44.0;      // 横杠条可点高度
static const CGFloat SBHomeBarSwipeDistance = 32.0; // 上滑回桌面的距离阈值（pt）
static const CGFloat SBHomeBarFastSwipeVelocity = 140.0; // 快滑速度阈值（pt/s）
static const NSTimeInterval SBHomeBarLongPressSeconds = 0.42; // 按住阈值
static const NSTimeInterval SBHomeBarPauseSeconds = 0.35;     // 上滑停顿阈值

static UIWindow *g_overlayWindow = nil;
static UILabel *g_toastLabel = nil;
static NSUInteger g_toastGeneration = 0;
static BOOL g_overlayInstalled = NO;

/// 除横杠条外不拦截触摸的容器视图。
@interface SBHomeBarPassthroughView : UIView
@property (nonatomic, weak, nullable) UIView *barView;
@end

@implementation SBHomeBarPassthroughView

- (nullable UIView *)hitTest:(CGPoint)point withEvent:(nullable UIEvent *)event {
    if (self.barView) {
        CGPoint pointInBar = [self convertPoint:point toView:self.barView];
        if ([self.barView pointInside:pointInBar withEvent:event]) {
            return [self.barView hitTest:pointInBar withEvent:event];
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

/// 回桌面 = 清掉启动标记（selection 与收据），宿主下次启动读不到 selection 即进桌面。
static void SBHomeBarGoHome(void) {
    const char *hostBundleID = getenv("SB_HOST_BUNDLE_ID");
    NSString *suite = (hostBundleID && hostBundleID[0] != '\0')
        ? [@"group." stringByAppendingString:[NSString stringWithUTF8String:hostBundleID]]
        : @"group.com.mjorb.sealbox";
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removeObjectForKey:@"SBSelectedGuestBundleID"];
    [defaults removeObjectForKey:@"SBSelectedGuestContainer"];
    [defaults removeObjectForKey:@"SBLaunchReceipt"];
    [defaults synchronize];
    exit(0);
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

- (void)handleDoubleTap:(UITapGestureRecognizer *)tap {
    SBHomeBarShowToast(@"切换器 v1 未提供");
}

@end

#pragma mark - 横杠搭建

static void SBHomeBarEnsureOverlay(void) {
    if (g_overlayWindow) {
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

    container.barView = barView;
    [container addSubview:barView];

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
}
