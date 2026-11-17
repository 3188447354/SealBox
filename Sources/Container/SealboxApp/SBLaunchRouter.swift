import Foundation

/// 进程启动时的路由：读启动标记，决定进桌面还是进客 App。
/// 客 App 的加载由 SBGuestLoader 完成；这里只做分流与收据处理。
enum SBLaunchRouter {
    /// 保证 Documents/Tweaks/SBGuestHooks.dylib 存在且与包内版本一致：
    /// 补丁注入的 LC_LOAD_DYLIB 指向它，自测也用它。包内位置是
    /// SealBox.app/Frameworks/SBGuestHooks.dylib（Embed Frameworks 落位）。
    /// 每次启动都比对大小，包内新了就覆盖拷一份。
    static func ensureGuestHooksDylib() {
        let fileManager = FileManager.default
        let documentsURL = SBConstants.documentsURL
        let tweaksDir = documentsURL.appendingPathComponent(SBConstants.tweaksDirectoryName)
        let destination = SBConstants.tweaksHookDylibURL(documentsURL: documentsURL)
        let embedded = Bundle.main.bundleURL
            .appendingPathComponent("Frameworks")
            .appendingPathComponent(SBConstants.guestHooksDylibName)
        guard fileManager.fileExists(atPath: embedded.path) else { return }
        do {
            try fileManager.createDirectory(at: tweaksDir, withIntermediateDirectories: true)
            let embeddedSize = (try? fileManager.attributesOfItem(atPath: embedded.path)[.size] as? NSNumber)?.int64Value
            let destSize = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
            if embeddedSize != destSize {
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: embedded, to: destination)
            }
        } catch {
            // 拷不过去不拦启动：加载客 App 时 bootstrap 会报缺件。
            NSLog("[Sealbox] SBGuestHooks.dylib 同步到 Tweaks 失败：%@", error.localizedDescription)
        }
    }

    /// App 启动时调用一次。若本次是“重起进客 App”，尝试加载客 App；
    /// 加载失败时清掉选中标记、留收据，回桌面弹错（由桌面在 appear 时按收据弹）。
    static func routeOnLaunchIfNeeded() {
        ensureGuestHooksDylib()
        guard SBGuestLoader.isGuestLaunchRequested() else {
            // 上次若留了未兑现的旧收据（重起请求被系统丢了），记一次失败，
            // 桌面出现时按收据提示“系统没有重启应用，请重试”。
            if var receipt = SBStore.shared.launchReceipt,
               receipt.stage == "restart-requested",
               Date().timeIntervalSince(receipt.createdAt) > SBConstants.restartDeadlineSeconds {
                receipt.stage = "guest-failed"
                receipt.stageDetail = SBError.restartRequestFailed.errorDescription
                SBStore.shared.launchReceipt = receipt
                SBStore.shared.recordLaunchResult(
                    bundleID: receipt.guestBundleID, success: false,
                    message: receipt.stageDetail ?? "系统没有重启应用，请重试")
            }
            return
        }
        let loaded = SBGuestLoader.shared().launchGuestIfRequested()
        if !loaded {
            // 客加载失败：SBGuestLoader 已写收据（guest-failed）与上次启动结果；
            // 清掉选中标记，回桌面。
            if let receipt = SBStore.shared.launchReceipt,
               receipt.stage == "guest-failed" {
                SBStore.shared.recordLaunchResult(
                    bundleID: receipt.guestBundleID, success: false,
                    message: receipt.stageDetail ?? "客 App 加载失败")
            }
            SBStore.shared.clearGuestSelection()
        }
    }
}
