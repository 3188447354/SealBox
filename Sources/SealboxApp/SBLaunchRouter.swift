import Foundation

/// 进程启动时的路由：读启动标记，决定进桌面还是进客 App。
/// 客 App 的加载由 SBGuestLoader 完成；这里只做分流与收据处理。
enum SBLaunchRouter {
    /// App 启动时调用一次。若本次是“重起进客 App”，尝试加载客 App；
    /// 加载失败时清掉选中标记、留收据，回桌面弹错（由桌面在 appear 时按收据弹）。
    static func routeOnLaunchIfNeeded() {
        guard SBGuestLoader.isGuestLaunchRequested() else {
            // 上次若留了未兑现的旧收据（重起请求被系统丢了），记一次失败，
            // 桌面出现时按收据提示“系统没有重启应用，请重试”。
            if var receipt = SBStore.shared.launchReceipt,
               receipt.stage == "restart-requested",
               Date().timeIntervalSince(receipt.createdAt) > SBConstants.restartDeadlineSeconds {
                receipt.stage = "guest-failed"
                receipt.stageDetail = SBError.restartRequestFailed.errorDescription
                SBStore.shared.launchReceipt = receipt
            }
            return
        }
        let loaded = SBGuestLoader.shared().launchGuestIfRequested()
        if !loaded {
            // 客加载失败：SBGuestLoader 已写收据（guest-failed）与上次启动结果；
            // 清掉选中标记，回桌面。
            SBStore.shared.clearGuestSelection()
        }
    }
}
