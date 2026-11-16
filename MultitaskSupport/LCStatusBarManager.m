//
//  LCStatusBarManager.m
//  LiveContainer
//
//  Created by Duy Tran on 20/2/26.
//
#import "LCStatusBarManager.h"
#import "LiveContainerSwiftUI-Swift.h"

@implementation LCStatusBarManager
- (void)handleTapAction:(UIAction *)action {
    if(self.nativeWindowViewController) {
        [self.nativeWindowViewController handleStatusBarTapAction:action];
        return;
    }
    // 0.0.7: the virtual window is gone, so there is no
    // windowHostingView to offer the tap to — fall through to the
    // system status-bar behaviour.
    [super handleTapAction:action];
}
@end

@implementation UIApplication(LiveContainer)
+ (Class)_statusBarManagerClass {
    if (@available(iOS 16.0, *)) {
        return LCStatusBarManager.class;
    } else {
        return UIStatusBarManager.class;
    }
}
@end
