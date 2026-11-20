import CryptoKit
import Foundation

/// 进程启动时的路由：读启动标记，决定进桌面还是进客 App。
/// 客 App 的加载由 SBGuestLoader 完成；这里只做分流与收据处理。
enum SBLaunchRouter {
    /// 0.2.19：包内件同步标记（包内 SBGuestHooks.dylib 的 SHA-256 hex），
    /// 记在 App Group UserDefaults（与已装记录同寿命）。
    private static let hooksSyncedHashKey = "SBGuestHooksSyncedHash"

    /// 保证 Documents/Tweaks/SBGuestHooks.dylib 存在且与包内版本一致：
    /// 补丁注入的 LC_LOAD_DYLIB 指向它，自测也用它。包内位置是
    /// SealBox.app/Frameworks/SBGuestHooks.dylib（Embed Frameworks 落位）。
    /// 0.2.19：按包内件 SHA-256 同步，不再按大小比对——大小比对会抹掉
    /// 已签好的件：Seal 签名件 106,400 字节、ZSign 重签件 121,552 字节，
    /// 都 != 包内未签名件 101,072 字节，每次 ensure 都把好签名拷回未
    /// 签名件，performEnsure 永远从未签名件出发重签（0.2.18 真机日志
    /// 18:54–18:57 十次重复的根因，见 build log 0.2.19 节）。
    /// 拷贝条件只剩三条：件缺失、件被截断（小于包内件）、包内件换了
    /// （新版本，标记对不上）。首次运行（无标记）且件已在位时不覆盖：
    /// 它可能带好签名，门+重签路径会在原地修它；包内件代码自 0.2.6
    /// 起没换过（0.2.17/0.2.18 两版 IPA 的包内件字节相同，
    /// md5 742fe5a5f18ef242b0c90c1467e7b935），不覆盖不会留旧代码。
    /// - Returns: 本次是否拷过种子。0.2.23：performEnsureHooksDylibSigned
    ///   拿它当强制重签的触发条件之一（刚拷的种子一律 ZSign 重签）。
    @discardableResult
    static func ensureGuestHooksDylib() -> Bool {
        let fileManager = FileManager.default
        let documentsURL = SBConstants.documentsURL
        let tweaksDir = documentsURL.appendingPathComponent(SBConstants.tweaksDirectoryName)
        let destination = SBConstants.tweaksHookDylibURL(documentsURL: documentsURL)
        let embedded = Bundle.main.bundleURL
            .appendingPathComponent("Frameworks")
            .appendingPathComponent(SBConstants.guestHooksDylibName)
        guard fileManager.fileExists(atPath: embedded.path),
              let embeddedData = try? Data(contentsOf: embedded) else { return false }
        let embeddedHash = SHA256.hash(data: embeddedData).map { String(format: "%02x", $0) }.joined()
        let defaults = UserDefaults(suiteName: SBConstants.appGroupSuiteName)
        var didCopy = false
        do {
            try fileManager.createDirectory(at: tweaksDir, withIntermediateDirectories: true)
            let destExists = fileManager.fileExists(atPath: destination.path)
            let destSize = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? -1
            let storedHash = defaults?.string(forKey: hooksSyncedHashKey)
            let needsCopy = !destExists
                || destSize < Int64(embeddedData.count)
                || (storedHash != nil && storedHash != embeddedHash)
            if needsCopy {
                if destExists {
                    try? fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: embedded, to: destination)
                didCopy = true
            }
            defaults?.set(embeddedHash, forKey: hooksSyncedHashKey)
        } catch {
            // 拷不过去不拦启动：加载客 App 时 bootstrap 会报缺件。
            NSLog("[Sealbox] SBGuestHooks.dylib 同步到 Tweaks 失败：%@", error.localizedDescription)
        }
        return didCopy
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
                bundleID: receipt.guestBundleID,
                diskDirectoryName: receipt.diskDirectoryName,
                success: false, message: message)
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
        // 看日志分不出来（0.2.12 的 hdsh 就是例子）。0.2.14：同一行里把
        // 失败标记的状态也记下来（上次死在 dlopen 签名失败与否 + 原因），
        // 门是放行还是触发修复、按什么输入决定的，日志里一次看清。
        let detail = SBCodesignCheck.signatureDetail(atPath: executablePath)
        let lastLaunchSigFailed = record.lastLaunchSigFailed
        let missingIDDylib = SBMachOHasIDDylib(executablePath) == 0
        SBDiagLog.log("启动路由验签：\(record.bundleID) \(executablePath) \(SBInstaller.signatureDetailFields(detail: detail)) 上次签名失败标记=\(lastLaunchSigFailed ? "是" : "否")\(record.lastLaunchResult.map { "（\($0.message.prefix(80))）" } ?? "") 缺LC_ID_DYLIB=\(missingIDDylib ? "是" : "否")")
        // 未签名记录：只记不拦（与点图标门一致——二进制可能无签名走 JIT；
        // 拦的活由 Team 门做，blockReceiptOnTeamMismatch 已跑过）。
        guard record.signed else { return .proceed }
        let detailValid = (detail["valid"] as? NSNumber)?.boolValue ?? false
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
    /// 0.2.25：修完不再进程内加载——宿主 UIKit 已初始化，客再调
    /// UIApplicationMain 必崩（nread 0.2.24 崩溃：Dispatch queue already
    /// set）。修完重新请求重启，让新进程在 UIKit 启动前走 main 前置路加载。
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
                SBDiagLog.log("启动路由：\(bundleID) 重启路重签完成，重新请求重启（新进程走 main 前置路）")
                await MainActor.run {
                    SBGuestLoader.shared().requestGuestLaunch(
                        withBundleID: bundleID,
                        containerUUID: record.containerUUID,
                        diskDirectoryName: record.diskDirectoryName,
                        keychainGroup: record.keychainGroup
                    ) { error in
                        if let error {
                            // 重启请求失败：按原有失败路径处理（guest-failed 收据 + 弹错）。
                            let message = error.localizedDescription
                            SBDiagLog.log("启动路由：\(bundleID) 修完重起请求失败（[code=\((error as NSError).code)] \(message)），不加载")
                            var failed = SBStore.shared.launchReceipt ?? SBLaunchReceipt.requested(
                                guestBundleID: bundleID,
                                containerUUID: record.containerUUID,
                                diskDirectoryName: record.diskDirectoryName,
                                keychainGroup: record.keychainGroup)
                            failed.stage = "guest-failed"
                            failed.stageDetail = message
                            SBStore.shared.launchReceipt = failed
                            SBStore.shared.recordLaunchResult(
                                bundleID: bundleID, diskDirectoryName: record.diskDirectoryName,
                                success: false, message: message)
                            SBStore.shared.clearGuestSelection()
                        } else {
                            SBDiagLog.log("启动路由：\(bundleID) 修完重起请求已发出，0.6 秒后退出进程")
                        }
                        onRepairSettled?()
                    }
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
                        bundleID: bundleID, diskDirectoryName: record.diskDirectoryName,
                        success: false, message: message)
                    SBStore.shared.clearGuestSelection()
                    onRepairSettled?()
                }
            }
        }
    }

    /// 0.2.25：main.m 在 UIKit 启动前调用的预检（见 SBGuestLaunchPreflight）。
    /// 收据就绪且逐项全过时返回 1——main.m 直接在 main 里加载客 App；
    /// 需要修复时返回 2——main.m 进宿主 UI 走异步修复（修完再重起一次）；
    /// 其余情况返回 0——进宿主 UI，沿用原有路由。
    /// 注意：这里跑的门与 routeOnLaunchIfNeeded 里的同一套（注入件同步、
    /// 对账、过期收据、Team 门、签名逐项门），顺序一致；幂等，多跑一遍无害。
    static func preflightForMainEntry() -> Int {
        guard SBGuestLoader.isGuestLaunchRequested() else { return 0 }
        ensureGuestHooksDylib()
        reconcileInstalledAppsWithDisk()
        clearStaleReceiptIfPackageMissing()
        if blockReceiptOnTeamMismatch() { return 0 }
        switch receiptSignatureGate() {
        case .proceed: return 1
        case .needsRepair: return 2
        }
    }

    /// 0.2.25：main 前置路加载失败时补记一次上次启动结果（与
    /// routeOnLaunchIfNeeded 的 `!loaded` 分支同款），否则“上次签名失败”
    /// 标记永远不更新，下一轮门看不到上次是死在签名上。
    /// 只在收据已是 guest-failed 时记；其余情况不做事。
    static func noteGuestLoadFailedIfNeeded() {
        guard let receipt = SBStore.shared.launchReceipt,
              receipt.stage == "guest-failed" else { return }
        SBStore.shared.recordLaunchResult(
            bundleID: receipt.guestBundleID,
            diskDirectoryName: receipt.diskDirectoryName,
            success: false,
            message: receipt.stageDetail ?? "客 App 加载失败")
        SBStore.shared.clearGuestSelection()
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
                    bundleID: receipt.guestBundleID,
                    diskDirectoryName: receipt.diskDirectoryName,
                    success: false,
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
        // 0.2.25：同步路是 main 前置路的兜底——正常情况下就绪的收据已被 main.m
        // 消费掉（预检通过直接加载、需修复走异步修复再重起），到这里说明前置路
        // 被绕过；仍按原有逻辑进程内加载一次，不静默丢掉这次启动。
        let loaded = SBGuestLoader.shared().launchGuestIfRequested()
        if !loaded {
            // 客加载失败：SBGuestLoader 已写收据（guest-failed）与上次启动结果；
            // 清掉选中标记，回桌面。
            if let receipt = SBStore.shared.launchReceipt,
               receipt.stage == "guest-failed" {
                SBStore.shared.recordLaunchResult(
                    bundleID: receipt.guestBundleID,
                    diskDirectoryName: receipt.diskDirectoryName,
                    success: false,
                    message: receipt.stageDetail ?? "客 App 加载失败")
            }
            SBStore.shared.clearGuestSelection()
        }
    }
}

/// 0.2.25：main.m 的 ObjC 可见桥——main.m 在 UIKit 启动前调 preflight()
/// 分流（见 SBLaunchRouter.preflightForMainEntry），加载失败时调
/// noteGuestLoadFailedIfNeeded() 补记上次启动结果。
@objc final class SBGuestLaunchPreflight: NSObject {
    /// - Returns: 0 = 无客启动请求或预检不通过（进宿主 UI）；
    ///   1 = 可直接在 main 里加载客 App；2 = 需要修复（进宿主 UI 走异步修复）。
    @objc static func preflight() -> Int {
        SBLaunchRouter.preflightForMainEntry()
    }

    /// main 前置路加载失败时补记一次上次启动结果（只在收据已是 guest-failed 时记）。
    @objc static func noteGuestLoadFailedIfNeeded() {
        SBLaunchRouter.noteGuestLoadFailedIfNeeded()
    }
}
