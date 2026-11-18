import SwiftUI
import UIKit

/// 桌面与各模块之间的接线：导入、启动、删除、设置、证书、收据弹错。
/// 桌面只管 UI 与手势，真实动作都在这里；GuestLoader 的证书门与看门狗在 ObjC 侧。
final class SBAppCoordinator: ObservableObject {

    struct CoordinatorAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        /// 证书门拦截时为 true：弹窗给“去导入证书”按钮，点后跳设置页证书区。
        var goToSettings = false
        /// 安装成功时为 true：弹窗给“去看看”按钮，点后回桌面第 2 页
        /// （已装应用那页）；“留在软件源”只关弹窗。
        var goToDesktop = false
        /// 0.2.9：包不在磁盘时为该应用：弹窗给“删除该应用”按钮（destructive），
        /// 点后直接删记录（SBAppDeletion 本就容忍包不在），不再只给
        /// “重新导入”一条死胡同；其余情况为 nil。
        var deleteApp: SBInstalledApp? = nil
    }

    struct DuplicatePending: Identifiable {
        let id = UUID()
        let parsed: SBParsedIPA
        let existing: SBInstalledApp
    }

    @Published var installProgress = SBInstallProgress()
    @Published var isInstalling = false
    /// 正在安装的应用显示名（下载闭环时为软件源目录名，文件导入时为解析出的显示名）；
    /// 获取按钮靠它判断“这行是不是正在装的那个”，只在那行显示真实进度。
    @Published var installingDisplayName: String?
    @Published var showingSettings = false
    @Published var deleteError: Error?
    @Published var activeAlert: CoordinatorAlert?
    @Published var duplicatePending: DuplicatePending?

    // MARK: - 顶层 presenter（文件选择器 / 密码框用）

    var topViewController: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: { $0.isKeyWindow })
            ?? scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - 导入（A3 / C1–C5）

    /// 导入入口：安装中不排队（C4），直接提示。
    func importIPA() {
        if isInstalling {
            activeAlert = CoordinatorAlert(title: "正在安装", message: "正在安装，请稍候")
            return
        }
        guard let presenter = topViewController else { return }
        Task {
            do {
                let url = try await SBImporter.pickIPA(presenter: presenter)
                await installIPA(at: url)
            } catch {
                // 用户取消静默处理（C1 的一部分），其余弹错。
                if case SBError.cancelled = error { return }
                await MainActor.run {
                    activeAlert = CoordinatorAlert(title: "导入失败", message: error.localizedDescription)
                }
            }
        }
    }

    /// 安装入口（文件选择器与软件源下载共用）：解析 → 同名查 → 三选一或直接装。
    /// - Parameters:
    ///   - url: Documents/IPAs 下的原始 IPA（下载完成后的落位文件，或选择器拷入的副本）。
    ///   - displayNameHint: 软件源目录名；解析出的显示名与它不一致时仍以它标安装行。
    func installIPA(at url: URL, displayNameHint: String? = nil) async {
        if isInstalling {
            await MainActor.run {
                activeAlert = CoordinatorAlert(title: "正在安装", message: "正在安装，请稍候")
            }
            return
        }
        do {
            let parsed = try SBIPAParser.parse(ipaURL: url)
            if let existing = SBStore.shared.app(with: parsed.bundleID) {
                await MainActor.run {
                    duplicatePending = DuplicatePending(parsed: parsed, existing: existing)
                }
                return
            }
            await runInstall(parsed: parsed, existing: nil, displayNameHint: displayNameHint)
        } catch {
            if case SBError.cancelled = error { return }
            await MainActor.run {
                installingDisplayName = nil
                activeAlert = CoordinatorAlert(title: "导入失败", message: error.localizedDescription)
            }
        }
    }

    /// 从 Documents/IPAs 的原始 IPA 重新跑一遍安装管线（详情页“重新安装”/
    /// 占位记录“重新导入”用）。同记录重装走替换路径（复用容器与钥匙串组）；
    /// 占位记录（needsReimport，旧 bundleID 未知）走全新安装，装完删占位记录。
    /// 原始 IPA 文件不在了，改走文件选择器导入。
    func reinstallApp(_ app: SBInstalledApp) {
        if isInstalling {
            activeAlert = CoordinatorAlert(title: "正在安装", message: "正在安装，请稍候")
            return
        }
        guard let fileName = app.sourceIPAFileName, !fileName.isEmpty else {
            importIPA()
            return
        }
        let ipaURL = SBConstants.documentsURL
            .appendingPathComponent("IPAs", isDirectory: true)
            .appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            activeAlert = CoordinatorAlert(
                title: "找不到原始 IPA",
                message: "Documents/IPAs 里没有该应用的原始 IPA 文件，请重新导入")
            return
        }
        Task {
            do {
                let parsed = try SBIPAParser.parse(ipaURL: ipaURL)
                if let existing = SBStore.shared.app(with: parsed.bundleID),
                   existing.recordID != app.recordID {
                    await MainActor.run {
                        duplicatePending = DuplicatePending(parsed: parsed, existing: existing)
                    }
                    return
                }
                if app.needsReimport {
                    await runInstall(parsed: parsed, existing: nil) {
                        SBStore.shared.removeAppRecord(recordID: app.recordID)
                        SBStore.shared.loadInstalledApps()
                    }
                } else {
                    await runInstall(parsed: parsed, existing: app)
                }
            } catch {
                if case SBError.cancelled = error { return }
                await MainActor.run {
                    activeAlert = CoordinatorAlert(title: "安装失败", message: error.localizedDescription)
                }
            }
        }
    }

    /// 同名选择：替换（复用旧容器与钥匙串组）或平行安装（新目录加时间戳后缀）。
    func resolveDuplicate(replace: Bool) {
        guard let pending = duplicatePending else { return }
        duplicatePending = nil
        Task {
            await runInstall(parsed: pending.parsed, existing: replace ? pending.existing : nil)
        }
    }

    /// 同名三选一 sheet 上点“取消”：什么都不装，解析临时目录已清。
    func cancelDuplicate() {
        installingDisplayName = nil
        duplicatePending = nil
    }

    /// 真安装：进度每 100ms 刷一次到桌面 pill；装完把新应用追加到桌面顺序末尾。
    /// - Parameters:
    ///   - displayNameHint: 软件源目录名；有它时安装行按它显示进度。
    ///   - onInstalled: 装完（记录已入库、桌面已刷新）后在主线程跑的收尾，
    ///     如占位记录重装成功后删占位记录；失败时不跑。
    private func runInstall(
        parsed: SBParsedIPA,
        existing: SBInstalledApp?,
        displayNameHint: String? = nil,
        onInstalled: (() -> Void)? = nil
    ) async {
        await MainActor.run {
            isInstalling = true
            installingDisplayName = displayNameHint ?? parsed.displayName
            installProgress.isInstalling = true
            installProgress.progress = 0
            installProgress.label = "正在安装 \(parsed.displayName)"
        }
        let progress = Progress(totalUnitCount: 100)
        let poll = Task {
            while !Task.isCancelled {
                let fraction = progress.fractionCompleted
                await MainActor.run { installProgress.progress = fraction }
                if fraction >= 1 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        do {
            let record = try await SBInstaller.install(parsed: parsed, progress: progress, existing: existing)
            poll.cancel()
            await MainActor.run {
                var order = SBStore.shared.desktopIconOrder
                if !order.contains(record.recordID.uuidString) {
                    order.append(record.recordID.uuidString)
                    SBStore.shared.desktopIconOrder = order
                }
                SBStore.shared.loadInstalledApps()
                installProgress.progress = 1
                installProgress.isInstalling = false
                installingDisplayName = nil
                isInstalling = false
                onInstalled?()
                // 安装成功必须有明确信号（0.2.1）：之前只在软件源那行把
                // 按钮翻成“已安装”，用户离开页面就看不到，装好的应用又
                // 在桌面第 2 页——不弹这一下，用户根本不知道装完了。
                activeAlert = CoordinatorAlert(
                    title: "已安装到桌面",
                    message: "“\(record.displayName)”已安装到桌面。",
                    goToDesktop: true)
            }
        } catch {
            poll.cancel()
            await MainActor.run {
                installProgress.isInstalling = false
                installingDisplayName = nil
                isInstalling = false
                if case SBError.cancelled = error { return }
                activeAlert = CoordinatorAlert(title: "安装失败", message: error.localizedDescription)
            }
        }
    }

    // MARK: - 启动（A4 / B1–B4）

    /// 当前启动阶段（30 秒看门狗超时提示用）：证书检查 / 重启请求 / 加载客 App 三档。
    /// 旧进程只走得到前两档——证书门与包检查在 requestGuestLaunch 内同步跑，
    /// 调用返回时回调还没来即已通过证书门，进入重启请求阶段；加载客 App 在新进程
    /// 的 bootstrap 里，旧进程在那之前已 exit(0)，看门狗随进程一起没了。
    private var launchStage: String?
    /// 30 秒后备看门狗：正常路径（成功 → 进程 exit(0)；失败 → 回调弹错）都会先取消它。
    private var launchWatchdog: DispatchWorkItem?
    /// 防重复点：点一次图标只发一次重启请求；失败 / 超时后清零，
    /// 成功时进程 exit(0)，旗标随进程一起没了。
    private var isLaunching = false

    /// 点图标后的真实启动：证书门与 5 秒看门狗在 GuestLoader 侧，失败回调里弹错。
    /// 另加 30 秒后备计时（F5）：从点图标起算，30 秒内无完成回调（进程未死、
    /// 无错误回调）则按当前阶段弹“启动超时（卡在：<阶段>），请重试”，超时后阶段清零。
    ///
    /// L2 JIT 预检（设计 §3.4，步骤 6 留下的债）：未签名（signed=false）或
    /// 需 JIT（needsJIT）的应用，先查 SBGuestLoader.isJITEnabled；未启用时
    /// 弹“该应用需要 JIT 才能运行”，不发启动请求、不假装启动。
    ///
    /// 0.2.2 注入件签名门：有证书时先跑 SBCertificate.ensureHooksDylibSigned，
    /// 保证 Tweaks 里的 SBGuestHooks.dylib 带着当前证书的 Team，成功才发重启
    /// 请求；签名失败直接弹错，不发重启（否则客 App 在新进程里加载注入件时
    /// 会被 dyld 以 Team 不一致拒绝——0.2.1 自测 dlopen 报的同一个根）。
    /// 无证书时跳过这一步，由重启请求里的证书门弹“去导入证书”。
    ///
    /// 0.2.6 重打补丁门：patchRevision 比当前低的已装应用（0.2.4 及更早装的
    /// 包，主可执行文件缺 LC_ID_DYLIB，dlopen 必败——0.2.5 真机实证），
    /// 先走 SBInstaller.repatchInstalledApp 重打补丁 + 重签，成功才继续；
    /// 失败弹错，不发重启请求。
    func launchApp(_ app: SBInstalledApp) {
        if app.needsReimport {
            activeAlert = CoordinatorAlert(
                title: "需重新导入",
                message: "该应用的安装信息缺失，请重新导入或删除")
            return
        }
        if app.signed == false || app.needsJIT {
            if !SBGuestLoader.isJITEnabled() {
                let message = (SBError.needsJIT.errorDescription ?? "该应用需要 JIT 才能运行")
                    + "。"
                    + (SBError.needsJIT.recoverySuggestion ?? "")
                activeAlert = CoordinatorAlert(title: SBError.needsJIT.stage, message: message)
                return
            }
        }
        guard !isLaunching else { return }
        isLaunching = true
        // 0.2.11：签名门无条件跑。0.2.10 真机实证（KMusic）：门只在有证书
        // 且记录 signed==true 时才跑，点图标后照常写收据、重启，新进程
        // 直接走到 dlopen 报 code signature invalid——门没跑等于没门。
        // Team 比对只看二进制本身（记录的 signed 旗标可能是旧的）；无证书
        // 时门只拦不修（ensureLaunchableSignature 内无证书不调 repatch）。
        // 注入件重签仍需证书：无证书时跳过它，直接发重启请求，由 ObjC 侧
        // 证书门弹“未导入证书”。
        Task {
            var appToLaunch = app
            do {
                // 0.2.6：旧版本装的包先重打补丁 + 重签（patchRevision < 2 的
                // 包主可执行文件缺 LC_ID_DYLIB，dlopen 必败——0.2.5 真机实证）。
                // 重打失败直接弹错，不发重启请求；无证书时不重打（修不了），
                // 直接进签名门（门能拦 Team/结构，不依赖证书）。
                if SBCertificate.hasCertificate,
                   app.patchRevision < SBConstants.patchRevision {
                    appToLaunch = try await SBInstaller.repatchInstalledApp(app)
                }
                // 0.2.8：启动前签名修复门。patchRevision 已是当前值也不等于
                // 签名是好的——Via 就是 0.2.5 安装时签了名、记录写 signed=true，
                // 点图标才由 dlopen 报 code signature invalid。先验签：结构
                // /CMS 坏或缺 LC_ID_DYLIB 就重打补丁+重签修一次；Team 不一致
                // 直接抛 teamMismatch，不白做工。
                // signed==false 的记录也比 Team：二进制可能带着签名（安装时
                // 签名失败却照装、或记录过期），只验结构会堵 JIT 的路，所以
                // 未签名记录只比 Team（无 Team 的二进制直接放行，走 JIT）。
                if appToLaunch.signed {
                    appToLaunch = try await SBInstaller.ensureLaunchableSignature(appToLaunch)
                } else {
                    try SBInstaller.checkTeamMatch(
                        appToLaunch.executableURL.path, bundleID: appToLaunch.bundleID)
                }
            } catch {
                // 0.2.10 报错日志：修复门（重打补丁/验签）失败之前只弹
                // 弹窗，诊断日志里没有这一行——看日志不知道修了什么、
                // 为什么修不好。
                SBDiagLog.log("启动失败：\(app.bundleID) \(app.executableURL.path) 签名修复门失败（[code=\(SBInstaller.errorCode(of: error))] \(error.localizedDescription)）")
                await MainActor.run {
                    self.isLaunching = false
                    self.activeAlert = CoordinatorAlert(
                        title: "启动失败",
                        message: self.launchRepairErrorMessage(error))
                }
                return
            }
            // 无证书：跳过注入件重签，直接发重启请求（ObjC 侧证书门会弹
            // “未导入证书”并给去导入证书按钮）。
            guard SBCertificate.hasCertificate else {
                await MainActor.run { self.requestRestart(app: appToLaunch) }
                return
            }
            // 0.2.8：Swift 6 下 @Sendable 闭包不能捕获 var——先把最终值
            // 定格成 let 再进 MainActor.run（0.2.8 第一轮 CI 红于此，
            // SBAppCoordinator.swift:309）。
            let launchTarget = appToLaunch
            let ok = await SBCertificate.ensureHooksDylibSigned()
            await MainActor.run {
                if ok {
                    self.requestRestart(app: launchTarget)
                } else {
                    // 0.2.10 报错日志：注入件签名失败之前只弹弹窗；失败
                    // 的具体原因（无证书/件不在/重签失败）由
                    // performEnsureHooksDylibSigned 记行，这里记弹窗决定。
                    SBDiagLog.log("启动失败：\(launchTarget.bundleID) 注入组件签名失败，弹启动失败（无法用当前证书签名 SBGuestHooks.dylib）")
                    self.isLaunching = false
                    self.activeAlert = CoordinatorAlert(
                        title: "启动失败",
                        message: "注入组件签名失败：无法用当前证书签名 SBGuestHooks.dylib，请重新导入证书后重试")
                }
            }
        }
    }

    /// 0.2.8：启动前签名修复失败的文案。Team 不一致是部署问题（宿主须与
    /// 客应用用同一证书签名），重签客应用修不好——不要给“删除后重新导入”
    /// 这种误导建议；其余失败（结构/CMS 坏、重打补丁失败）给重装建议。
    private func launchRepairErrorMessage(_ error: Error) -> String {
        if let sbError = error as? SBError, case .teamMismatch = sbError {
            // 0.2.11：teamMismatch 弹窗给部署指导——只说“不一致”用户
            // 不知道怎么办，补上恢复建议（宿主须用同一证书签名）。
            return (sbError.errorDescription ?? "Team 不一致")
                + "。" + (sbError.recoverySuggestion ?? "")
        }
        return "旧版本应用升级失败：\(error.localizedDescription)，请删除后重新导入"
    }

    /// 发重启请求（launchApp 的后半段，签名门通过后才进）。
    private func requestRestart(app: SBInstalledApp) {
        launchWatchdog?.cancel()
        launchWatchdog = nil
        launchStage = "证书检查"
        let bundleID = app.bundleID
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let stage = self.launchStage ?? "重启请求"
            // 0.2.10 报错日志：之前只弹“启动超时”，诊断日志里没有这一行。
            SBDiagLog.log("启动超时：\(bundleID) 卡在：\(stage)（30 秒看门狗，重启请求未回）")
            self.launchStage = nil
            self.launchWatchdog = nil
            self.isLaunching = false
            self.activeAlert = CoordinatorAlert(title: "启动超时", message: "启动超时（卡在：\(stage)），请重试")
        }
        launchWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: watchdog)
        SBGuestLoader.shared().requestGuestLaunch(
            withBundleID: app.bundleID,
            containerUUID: app.containerUUID,
            diskDirectoryName: app.diskDirectoryName,
            keychainGroup: app.keychainGroup
        ) { [weak self] error in
            guard let self = self else { return }
            self.launchWatchdog?.cancel()
            self.launchWatchdog = nil
            self.launchStage = nil
            guard let error = error else { return }
            self.isLaunching = false
            let stage = (error as NSError).userInfo[SBGuestLoaderErrorStageKey] as? String ?? "启动失败"
            // 0.2.10 报错日志：重启请求失败之前只弹弹窗；原因（证书门/
            // 包缺失/看门狗/openURL）已由 ObjC 侧记行，这里记弹窗决定。
            SBDiagLog.log("启动失败弹窗：[code=\((error as NSError).code)] \(app.bundleID) 阶段：\(stage) \(error.localizedDescription)")
            Task { @MainActor in
                if (error as NSError).code == SBGuestLoaderErrorCode.bundleNotFound.rawValue {
                    // 0.2.9：包不在磁盘（记录还在，多为宿主重装换了容器）——
                    // 不要只给“重新导入”死胡同，弹窗直接给“删除该应用”。
                    self.activeAlert = CoordinatorAlert(
                        title: stage,
                        message: error.localizedDescription,
                        deleteApp: app)
                } else {
                    // 证书门拦截（无证书 / 证书被删 / 证书过期）给“去导入证书”按钮，
                    // 点后关弹窗并打开设置页（证书区在设置页内）。
                    self.activeAlert = CoordinatorAlert(
                        title: stage,
                        message: error.localizedDescription,
                        goToSettings: stage == "证书检查")
                }
            }
        }
        // 证书门与包检查已同步跑完：回调还没来 = 已通过证书门，进入重启请求阶段。
        // （证书失败 / 包缺失时回调是同步调的，上面已把 launchStage 置 nil，不会误推进。）
        if launchStage != nil {
            launchStage = "重启请求"
        }
    }

    // MARK: - 删除（A7）

    func deleteApp(_ app: SBInstalledApp) {
        Task {
            do {
                try SBAppDeletion.delete(app: app)
                await MainActor.run {
                    SBStore.shared.loadInstalledApps()
                    deleteError = nil
                }
            } catch {
                await MainActor.run { deleteError = error }
            }
        }
    }

    // MARK: - 证书（A2 / B6）

    /// 缺证书引导与设置页共用：走证书导入流程，取消静默、失败弹错。
    func importCertificate() {
        guard let presenter = topViewController else { return }
        Task {
            do {
                try await SBCertificate.importP12(presenter: presenter)
            } catch {
                if case SBError.cancelled = error { return }
                await MainActor.run {
                    activeAlert = CoordinatorAlert(title: "导入证书失败", message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - 收据弹错（B4：启动失败回桌面时按收据弹一次）

    func showGuestFailedReceiptIfNeeded() {
        guard let receipt = SBStore.shared.launchReceipt, receipt.stage == "guest-failed" else { return }
        let message = receipt.stageDetail ?? "客 App 加载失败"
        SBStore.shared.launchReceipt = nil
        // 0.2.10 报错日志：收据的失败原因已在加载时记行；这里记收据
        // 被桌面弹出来并清掉，收尾可追溯。
        SBDiagLog.log("启动失败弹窗：\(receipt.guestBundleID) 按 guest-failed 收据弹错（\(message)），收据已清")
        activeAlert = CoordinatorAlert(title: "启动失败", message: message)
    }
}
