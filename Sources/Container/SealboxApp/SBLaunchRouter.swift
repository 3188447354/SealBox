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

    /// 0.2.11：新进程加载前第二道 Team 门——收据可能由旧版本点图标写下
    ///（那时门还没修好、或根本没跑），只拦“点图标时”不够。新进程在 dlopen
    /// 之前再比一次：Team 不一致就不加载，直接把收据写成 guest-failed、
    /// 弹 teamMismatch 明文，不再报原始 dlopen 长文。
    /// 只比 Team，不验结构：未签名（无 Team）的二进制直接放行（走 JIT）；
    /// 结构坏的仍由加载器按 dlopen 报错。收据不在待处理阶段、找不到记录、
    /// 可执行文件不在时不拦（交给已有的清收据/加载流程处理）。
    /// - Returns: true 表示已拦截（调用方直接 return，不再加载）。
    private static func blockReceiptOnTeamMismatch() -> Bool {
        guard let receipt = SBStore.shared.launchReceipt,
              receipt.stage == "restart-requested"
                || receipt.stage == "restart-confirmed" else { return false }
        let record = SBStore.shared.installedApps.first {
            $0.bundleID == receipt.guestBundleID
            && $0.diskDirectoryName == receipt.diskDirectoryName
        } ?? SBStore.shared.app(with: receipt.guestBundleID)
        guard let record = record else { return false }
        let executablePath = record.executableURL.path
        guard FileManager.default.fileExists(atPath: executablePath) else { return false }
        do {
            try SBInstaller.checkTeamMatch(executablePath, bundleID: record.bundleID)
            return false
        } catch {
            // checkTeamMatch 只抛 teamMismatch（客无 Team 时不抛）；其他错误
            // 理论上到不了这里，保险起见只拦 teamMismatch，其余交给加载器。
            guard case SBError.teamMismatch = error else { return false }
            let message = error.localizedDescription
            SBDiagLog.log("启动路由：\(receipt.guestBundleID) \(executablePath) Team 门拦截（[code=\(SBInstaller.errorCode(of: error))] \(message)），不加载")
            var failed = receipt
            failed.stage = "guest-failed"
            failed.stageDetail = message
            SBStore.shared.launchReceipt = failed
            SBStore.shared.recordLaunchResult(
                bundleID: receipt.guestBundleID, success: false, message: message)
            SBStore.shared.clearGuestSelection()
            return true
        }
    }

    /// 0.2.13：重启路消费收据前的完整签名逐项门。
    /// 根因（0.2.12 真机实证，2026-11-19 11:59）：hdsh 在 09:52 的旧检查
    /// 里全过（9492 页、CMS 在位、Team 一致），收据由 0.2.11 在 09:52 写下；
    /// 0.2.12 重启后只走了 blockReceiptOnTeamMismatch（只比 Team，不验结构），
    /// 新门没机会拦它，dlopen 照样报 code signature invalid（errno=85，
    /// codeBlobOffset=0x02513CE0）。点图标门（ensureLaunchableSignature，
    /// 全逐项 + 强制重签）只在点图标时跑；重启路是另一套逻辑。
    /// 收据本身没有门版本字段（ObjC 写 JSON，Swift 只读），旧版本收据无法
    /// 区分——所以重启路对所有收据一律视为未验签，无条件重跑逐项。
    /// 快查同步跑（逐项解析是纯计算）；需要修时不阻塞启动主线程，返回
    /// needsRepair，由 routeOnLaunchIfNeeded 走异步修复 + 加载。
    private enum ReceiptSignatureGate {
        /// 逐项全过且上次不是签名失败且 LC_ID_DYLIB 在：直接走 dlopen
        ///（今天的行为，不变）。
        case proceed
        /// 逐项有坏项、或上次死在 dlopen 签名失败、或缺 LC_ID_DYLIB：
        /// 异步强制重打补丁 + 重签。
        case needsRepair
    }

    private static func receiptSignatureGate() -> ReceiptSignatureGate {
        guard let receipt = SBStore.shared.launchReceipt,
              receipt.stage == "restart-requested"
                || receipt.stage == "restart-confirmed" else { return .proceed }
        let record = SBStore.shared.installedApps.first {
            $0.bundleID == receipt.guestBundleID
            && $0.diskDirectoryName == receipt.diskDirectoryName
        } ?? SBStore.shared.app(with: receipt.guestBundleID)
        guard let record = record else { return .proceed }
        let executablePath = record.executableURL.path
        guard FileManager.default.fileExists(atPath: executablePath) else { return .proceed }
        // 先记一行逐项——重启路以前连这行都没有，坏签是放行还是根本没验，
        // 看日志分不出来（0.2.12 的 hdsh 就是例子）。
        let detail = SBCodesignCheck.signatureDetail(atPath: executablePath)
        SBDiagLog.log("启动路由验签：\(record.bundleID) \(executablePath) \(SBInstaller.signatureDetailFields(detail: detail))")
        // 未签名记录：只记不拦（与点图标门一致——二进制可能无签名走 JIT；
        // 拦的活由 Team 门做，blockReceiptOnTeamMismatch 已跑过）。
        guard record.signed else { return .proceed }
        let detailValid = (detail["valid"] as? NSNumber)?.boolValue ?? false
        // 与 ensureLaunchableSignature 同款判断：上次启动是不是死在 dlopen
        // 签名失败（记录里的上次结果由启动路由在加载失败时写回）。
        let lastLaunchSigFailed = record.lastLaunchResult?.success == false
            && (record.lastLaunchResult?.message.contains("code signature invalid") ?? false)
        let missingIDDylib = SBMachOHasIDDylib(executablePath) == 0
        if detailValid && !lastLaunchSigFailed && !missingIDDylib {
            return .proceed
        }
        return .needsRepair
    }

    /// 0.2.13：重启路的异步修复 + 加载。重打补丁 + 重签是秒级重活
    ///（ZSign 全包重签），不能阻塞启动主线程（看门狗 20 秒）；修完回主
    /// 线程加载客 App（客 main 是 UIKit，必须主线程）。修不好时写
    /// guest-failed 收据、记上次启动结果，onRepairSettled 回主线程让调用
    /// 方按收据弹错——不许静默失败。
    private static func repairAndLaunchGuest(onRepairSettled: (@MainActor @Sendable () -> Void)?) {
        Task {
            guard let receipt = SBStore.shared.launchReceipt else { return }
            let record = SBStore.shared.installedApps.first {
                $0.bundleID == receipt.guestBundleID
                && $0.diskDirectoryName == receipt.diskDirectoryName
            } ?? SBStore.shared.app(with: receipt.guestBundleID)
            guard let record = record else { return }
            let bundleID = record.bundleID
            do {
                SBDiagLog.log("启动路由：\(bundleID) 重启路签名逐项不合格或上次死在 dlopen 签名失败，异步强制重打补丁+重签")
                _ = try await SBInstaller.ensureLaunchableSignature(record)
                SBDiagLog.log("启动路由：\(bundleID) 重启路重签完成，开始加载客 App")
                let loaded = await MainActor.run {
                    SBGuestLoader.shared().launchGuestIfRequested()
                }
                await MainActor.run {
                    if !loaded {
                        // 客加载失败：SBGuestLoader 已写收据（guest-failed）；
                        // 清掉选中标记，回桌面。
                        if let failedReceipt = SBStore.shared.launchReceipt,
                           failedReceipt.stage == "guest-failed" {
                            SBStore.shared.recordLaunchResult(
                                bundleID: failedReceipt.guestBundleID, success: false,
                                message: failedReceipt.stageDetail ?? "客 App 加载失败")
                        }
                        SBStore.shared.clearGuestSelection()
                    }
                    onRepairSettled?()
                }
            } catch {
                // 修不好：ensureLaunchableSignature 的错误文案已写明 exact
                // 坏项——写 guest-failed 收据、记失败，绝不走到 dlopen。
                let message = error.localizedDescription
                await MainActor.run {
                    SBDiagLog.log("启动路由：\(bundleID) 重启路重签失败（[code=\(SBInstaller.errorCode(of: error))] \(message)），不加载")
                    var failed = SBStore.shared.launchReceipt ?? SBLaunchReceipt.requested(
                        guestBundleID: bundleID,
                        containerUUID: record.containerUUID,
                        diskDirectoryName: record.diskDirectoryName,
                        keychainGroup: record.keychainGroup)
                    failed.stage = "guest-failed"
                    failed.stageDetail = message
                    SBStore.shared.launchReceipt = failed
                    SBStore.shared.recordLaunchResult(
                        bundleID: bundleID, success: false, message: message)
                    SBStore.shared.clearGuestSelection()
                    onRepairSettled?()
                }
            }
        }
    }

    /// App 启动时调用一次。若本次是“重起进客 App”，尝试加载客 App；
    /// 加载失败时清掉选中标记、留收据，回桌面弹错（由桌面在 appear 时按收据弹）。
    /// - Parameter onRepairSettled: 0.2.13：重启路需要异步修复时（签名逐项不
    ///   合格），修复完成后回主线程调一次——调用方借此按收据弹错；同步路
    ///   （直接加载或 Team 门拦截）不调它，调用方照常在 route 返回后弹错。
    static func routeOnLaunchIfNeeded(onRepairSettled: (@MainActor @Sendable () -> Void)? = nil) {
        ensureGuestHooksDylib()
        reconcileInstalledAppsWithDisk()
        clearStaleReceiptIfPackageMissing()
        // 0.2.11：新进程加载前第二道 Team 门（见 blockReceiptOnTeamMismatch）。
        if blockReceiptOnTeamMismatch() { return }
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
        // 0.2.13：重启路的签名逐项门（见 receiptSignatureGate）。快查同步；
        // 需要修时走异步修复 + 加载，不阻塞启动主线程。
        switch receiptSignatureGate() {
        case .proceed:
            break
        case .needsRepair:
            repairAndLaunchGuest(onRepairSettled: onRepairSettled)
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
