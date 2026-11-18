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

    /// 0.2.9：启动时对账——记录在 App Group UserDefaults 里，包在宿主自己的
    /// Documents 里，两边寿命不一样：宿主删了重装会换数据容器，包没了，记录
    /// 还在（KYNS 真机实证：记录与收据都在 App Group 里活着，包在新容器
    /// 里没有）。包不在的记录标 needsReimport——只标、不删：用户导入的包
    /// 永不自动回收。标灰后点图标进详情页，给“重新安装 / 删除此应用”。
    /// 安装只在包落位后才入库，所以启动时包不在即记录已失效，不存在误删。
    static func reconcileInstalledAppsWithDisk() {
        let apps = SBStore.shared.loadInstalledApps()
        var updated = apps
        var changed = false
        for i in updated.indices {
            let app = updated[i]
            if app.needsReimport || app.diskDirectoryName.isEmpty { continue }
            if !FileManager.default.fileExists(atPath: app.bundleURL.path) {
                updated[i].needsReimport = true
                changed = true
                SBDiagLog.log("启动对账：\(app.bundleID) \(app.bundleURL.path) 包不在磁盘，标为需重新导入")
            }
        }
        if changed {
            SBStore.shared.saveInstalledApps(updated)
        }
    }

    /// 0.2.10：收据与对账的接线——对账刚把记录标灰，路由紧接着就按收据去
    /// 加载，最后还是报“找不到安装包”（0.2.9 真机实证：com.xuncorp.sp）。
    /// 收据可能在记录标灰之前写下（旧版本点图标、或看门狗刷新 createdAt
    /// 后残留），只拦“写收据时”不够。路由处理收据前先看这张收据的包还
    /// 在不在：包不在就不加载，清掉收据，不记失败、不弹启动失败；记录已
    /// 标灰，点图标进详情页（重新安装 / 删除此应用）。
    /// guest-failed 收据同样处理：包不在的失败是旧的孤儿收据，清掉，
    /// 不再弹一次启动失败。
    private static func clearStaleReceiptIfPackageMissing() {
        guard let receipt = SBStore.shared.launchReceipt else { return }
        guard receipt.stage == "restart-requested"
            || receipt.stage == "restart-confirmed"
            || receipt.stage == "guest-failed" else { return }
        // 记录已标 needsReimport 即不再启动——哪怕包还在磁盘上（占位记录）。
        let record = SBStore.shared.installedApps.first {
            $0.bundleID == receipt.guestBundleID
            && $0.diskDirectoryName == receipt.diskDirectoryName
        } ?? SBStore.shared.app(with: receipt.guestBundleID)
        if record?.needsReimport == true {
            SBDiagLog.log("启动路由：\(receipt.guestBundleID) \(record?.bundleURL.path ?? "") 已标需重新导入，跳过客加载并清掉过期收据")
            SBStore.shared.launchReceipt = nil
            SBStore.shared.clearGuestSelection()
            return
        }
        // 收据自带的目录名就是加载器要用的路径（平行安装靠它区分），直接验盘。
        let dirName = receipt.diskDirectoryName.isEmpty
            ? receipt.guestBundleID + ".app" : receipt.diskDirectoryName
        let packageURL = SBConstants.documentsURL
            .appendingPathComponent(SBConstants.guestAppsDirectoryName)
            .appendingPathComponent(dirName)
        if !FileManager.default.fileExists(atPath: packageURL.path) {
            SBDiagLog.log("启动路由：\(receipt.guestBundleID) \(packageURL.path) 包不在磁盘，跳过客加载并清掉过期收据")
            SBStore.shared.launchReceipt = nil
            SBStore.shared.clearGuestSelection()
        }
    }

    /// App 启动时调用一次。若本次是“重起进客 App”，尝试加载客 App；
    /// 加载失败时清掉选中标记、留收据，回桌面弹错（由桌面在 appear 时按收据弹）。
    static func routeOnLaunchIfNeeded() {
        ensureGuestHooksDylib()
        reconcileInstalledAppsWithDisk()
        clearStaleReceiptIfPackageMissing()
        guard SBGuestLoader.isGuestLaunchRequested() else {
            // 客已退出或闪退过：收据残留 guest-loaded 时静默清除，不弹错、不记失败，
            // 避免下次启动误判（设计 §5.5 的 guest-loaded 过期清理）。
            if let receipt = SBStore.shared.launchReceipt, receipt.stage == "guest-loaded" {
                SBStore.shared.launchReceipt = nil
                SBStore.shared.clearGuestSelection()
                return
            }
            // 上次若留了未兑现的旧收据（重起请求被系统丢了），记一次失败，
            // 桌面出现时按收据提示“系统没有重启应用，请重试”。
            if var receipt = SBStore.shared.launchReceipt,
               receipt.stage == "restart-requested",
               Date().timeIntervalSince(receipt.createdAt) > SBConstants.restartDeadlineSeconds {
                // 0.2.10 报错日志：之前进这个分支（收据过期记 guest-failed）
                // 没有日志行——下次启动看到 guest-failed 收据，不知道是
                // 哪张收据、过期多久。
                let age = Date().timeIntervalSince(receipt.createdAt)
                SBDiagLog.log("启动路由：\(receipt.guestBundleID) 重启收据过期（\(String(format: "%.1f", age)) 秒 > \(SBConstants.restartDeadlineSeconds) 秒，[code=1003]），记启动失败")
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
