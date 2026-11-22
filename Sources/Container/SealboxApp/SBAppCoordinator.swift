import SwiftUI
import UIKit

extension Notification.Name {
    /// 0.2.37：安装完成——导入不再弹“已安装到桌面”（MJ 22:35）。根视图接到后
    /// 回桌面第 2 页，新图标直接落在眼前（coordinator 不持有 VMState，用通知接线）。
    static let SBInstallCompleted = Notification.Name("SBInstallCompleted")
}

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
    /// 0.2.44（F6）：正在启动的客 bundleID——点按即显示加载态（HomeScreenView
    /// 叠一层 spinner＋“正在启动…”），成功／失败回调里清掉。恢复路是同步的，
    /// 不设它（恢复不走签名门、不经过这里的 Task）。
    @Published var launchingBundleID: String?

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
    /// 0.2.37：导入全程不弹任何提示（MJ 22:35）——安装中再次点导入只静默忽略
    ///（桌面安装 pill 已在显示进度），失败只记日志；成功也不弹，见 runInstall。
    func importIPA() {
        if isInstalling {
            SBDiagLog.log("导入 IPA：正在安装，忽略重复导入请求")
            return
        }
        guard let presenter = topViewController else { return }
        Task {
            do {
                let url = try await SBImporter.pickIPA(presenter: presenter)
                await installIPA(at: url)
            } catch {
                // 用户取消静默处理（C1 的一部分），其余只记日志，不弹错。
                if case SBError.cancelled = error { return }
                SBDiagLog.log("导入 IPA 失败：\(error.localizedDescription)")
            }
        }
    }

    /// 安装入口（文件选择器与软件源下载共用）：解析 → 同名查 → 三选一或直接装。
    /// - Parameters:
    ///   - url: Documents/IPAs 下的原始 IPA（下载完成后的落位文件，或选择器拷入的副本）。
    ///   - displayNameHint: 软件源目录名；解析出的显示名与它不一致时仍以它标安装行。
    func installIPA(at url: URL, displayNameHint: String? = nil) async {
        if isInstalling {
            SBDiagLog.log("安装 IPA：正在安装，忽略重复安装请求")
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
            }
            // 0.2.37：导入失败不弹错，只记日志（MJ 22:35）。
            SBDiagLog.log("安装 IPA 失败：\(error.localizedDescription)")
        }
    }

    /// 从 Documents/IPAs 的原始 IPA 重新跑一遍安装管线（详情页“重新安装”/
    /// 占位记录“重新导入”用）。同记录重装走替换路径（复用容器与钥匙串组）；
    /// 占位记录（needsReimport，旧 bundleID 未知）走全新安装，装完删占位记录。
    /// 原始 IPA 文件不在了，改走文件选择器导入。
    func reinstallApp(_ app: SBInstalledApp) {
        if isInstalling {
            SBDiagLog.log("重新安装：正在安装，忽略重复安装请求")
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
            // 0.2.37：原始 IPA 不在了不弹错，直接走文件选择器让用户重新挑
            //（与本方法文档注释一致；以前这里弹“找不到原始 IPA”）。
            SBDiagLog.log("重新安装：Documents/IPAs 里没有 \(fileName)，走文件选择器重新导入")
            importIPA()
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
                // 0.2.37：重装失败不弹错，只记日志；有旧记录的标需重新导入，
                // 桌面上灰显、详情页可重新导入（MJ 22:35：导入不要弹窗）。
                SBDiagLog.log("重新安装失败：\(error.localizedDescription)")
                await MainActor.run {
                    markRecordNeedsReimport(app)
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
        // 0.2.26 G9：LC 同款（LCAppInfo.m:303）——安装中途崩溃检测：入口置旗，
        // 退出清掉；下次进宿主 UI 时残留为真即报“上次安装中途崩溃”一次。
        SBStore.shared.signingInProgress = true
        defer { SBStore.shared.signingInProgress = false }
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
                // 0.2.37：安装成功不再弹“已安装到桌面”（MJ 22:35：导入不要弹窗）。
                // 明确信号改为直接回桌面第 2 页——新图标就落在眼前；通知由根视图
                // 接（coordinator 不持有 VMState，见 VMRootView 的 onReceive）。
                SBDiagLog.log("安装完成：\(record.displayName) 已安装到桌面")
                NotificationCenter.default.post(name: .SBInstallCompleted, object: nil)
            }
        } catch {
            poll.cancel()
            await MainActor.run {
                installProgress.isInstalling = false
                installingDisplayName = nil
                isInstalling = false
                if case SBError.cancelled = error { return }
                // 0.2.37：安装失败不弹错，只记日志；有旧记录（重装/替换）的标
                // 需重新导入，桌面灰显、详情页可重新导入（MJ 22:35）。
                SBDiagLog.log("安装失败：\(error.localizedDescription)")
                if let existing {
                    markRecordNeedsReimport(existing)
                }
            }
        }
    }

    /// 把一条已装记录标为需重新导入（安装/重装失败时用）：桌面灰显，详情页给
    /// “重新安装 / 删除此应用”。无该记录时静默无操作。
    private func markRecordNeedsReimport(_ record: SBInstalledApp) {
        var apps = SBStore.shared.loadInstalledApps()
        guard let index = apps.firstIndex(where: { $0.recordID == record.recordID }) else { return }
        apps[index].needsReimport = true
        SBStore.shared.saveInstalledApps(apps)
        SBStore.shared.loadInstalledApps()
        SBDiagLog.log("安装失败：\(record.displayName) 已标需重新导入")
    }

    // MARK: - 启动（A4 / B1–B4）

    /// 当前启动阶段（超时提示用）：证书检查 / 进程内加载 / 加载客 App 三档。
    /// 旧进程只走得到前两档——证书门与包检查在 requestGuestLaunch 内同步跑，
    /// 当前启动阶段（弹“启动超时”时用；0.2.27：加载是同步的，不再设看门狗）。
    private var launchStage: String?
    /// 0.2.27：异步激活失败通知的观察者（会话管理器在 scene 驱动无窗时发；
    /// 宿主界面已在前台，按通知弹错——收据已写成 guest-failed）。
    private var activationFailedObserver: NSObjectProtocol?
    /// 防重复点：点一次图标只发一次加载请求；失败后清零，
    /// 成功时客进前台，旗标由回调清零。
    private var isLaunching = false

    init() {
        activationFailedObserver = NotificationCenter.default.addObserver(
            // 0.2.27 fixup 2：ObjC `NSString * const ...Notification` 常量在
            // Swift 侧导入成 NSNotification.Name 的静态成员（原全局名被改名，
            // 直接写 SBGuestActivationFailedNotification 编译报 renamed）。
            forName: NSNotification.Name.SBGuestActivationFailed,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let message = note.userInfo?[SBGuestActivationFailedMessageKey] as? String
                ?? "客 App 启动失败"
            SBDiagLog.log("启动失败弹窗：客 App 激活失败（\(message)）")
            self.activeAlert = CoordinatorAlert(title: "启动失败", message: message)
        }
    }

    /// 点图标后的真实启动：证书门与 5 秒看门狗在 GuestLoader 侧，失败回调里弹错。
    /// 0.2.27：加载是同步的（dlopen→拦截→跳 main，hook 激活后 main 随即返回），
    /// 主线程在加载期间被占用，同线程的计时器跑不起来，所以不再设 30 秒后备计时。
    ///
    /// L2 JIT 预检（设计 §3.4，步骤 6 留下的债）：未签名（signed=false）或
    /// 需 JIT（needsJIT）的应用，先查 SBGuestLoader.isJITEnabled；未启用时
    /// 弹“该应用需要 JIT 才能运行”，不发启动请求、不假装启动。
    ///
    /// 0.2.2 注入件签名门：有证书时先跑 SBCertificate.ensureHooksDylibSigned，
    /// 保证 Tweaks 里的 SBGuestHooks.dylib 带着当前证书的 Team，成功才发启动
    /// 请求；签名失败直接弹错，不发启动（否则客 App 在加载注入件时
    /// 会被 dyld 以 Team 不一致拒绝——0.2.1 自测 dlopen 报的同一个根）。
    /// 无证书时跳过这一步，由启动请求里的证书门弹“去导入证书”。
    ///
    /// 0.2.6 重打补丁门：patchRevision 比当前低的已装应用（0.2.4 及更早装的
    /// 包，主可执行文件缺 LC_ID_DYLIB，dlopen 必败——0.2.5 真机实证），
    /// 先走 SBInstaller.repatchInstalledApp 重打补丁 + 重签，成功才继续；
    /// 失败弹错，不发启动请求。
    func launchApp(_ app: SBInstalledApp) {
        // 0.2.44（F3 计量）：点图标行——真实点按时间，后续“已激活”行与它
        // 相减即点图标→已激活全流程耗时（0.2.43 日志里这行不存在，耗时
        // 只能从“进 SealboxApp”这类行反推）。
        SBDiagLog.log("点图标：\(app.bundleID)（\(app.displayName)）")
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
        guard !isLaunching else {
            // 0.2.36：之前这里静默 return，日志里看不出点图标被吞了——
            // 0.2.35 真机 Husk 首次打开成功后旗标永不清，再点直接消失。
            SBDiagLog.log("点图标：\(app.bundleID) 启动进行中，忽略重复点（isLaunching=true）")
            return
        }
        // 0.2.36：恢复路放防重旗前面——恢复是同步的、不走签名门、不设旗；
        // 即使将来某路漏清旗标，点后台客也必须能恢复，不能被旗标静默吞掉。
        // 恢复失败（上下文重上失败）弹错并停住；返回 false（无会话）时落到首次加载。
        // 0.2.27：已开过的客走恢复路径（不 dlopen、不跑 main、不重调
        // didFinishLaunching），不走签名门（首次加载时已验过，二进制未变）。
        if SBGuestSessionManager.shared().session(forBundleID: app.bundleID) != nil {
            // 0.2.27 fixup 4：resumeGuest 不带 NSError**（见头文件注释），
            // Swift 侧得可选会话：非空=已恢复；空+lastResumeError 非空=恢复失败弹错；
            // 空+lastResumeError 为空=无会话，落到首次加载。
            if SBGuestSessionManager.shared().resumeGuest(withBundleID: app.bundleID) != nil {
                SBDiagLog.log("点图标：\(app.bundleID) 已在后台，恢复进入（未重加载）")
                return
            }
            if let resumeError = SBGuestSessionManager.shared().lastResumeError {
                SBDiagLog.log("启动失败：\(app.bundleID) 恢复后台会话失败（\(resumeError.localizedDescription)）")
                self.activeAlert = CoordinatorAlert(title: "启动失败", message: resumeError.localizedDescription)
                return
            }
        }
        isLaunching = true
        // 0.2.44（F6）：点按即显示加载态——设 launchingBundleID，桌面立即
        // 叠 spinner＋“正在启动…”，不再是 0.12 秒按压缩放后一片静默。
        launchingBundleID = app.bundleID
        SBDiagLog.log("点图标：\(app.bundleID) 加载态已显示")
        // 0.2.11：签名门无条件跑。0.2.10 真机实证（KMusic）：门只在有证书
        // 且记录 signed==true 时才跑，点图标后照常写收据、加载，当前进程
        // 直接走到 dlopen 报 code signature invalid——门没跑等于没门。
        // Team 比对只看二进制本身（记录的 signed 旗标可能是旧的）；无证书
        // 时门只拦不修（ensureLaunchableSignature 内无证书不调 repatch）。
        // 注入件重签仍需证书：无证书时跳过它，直接发启动请求，由 ObjC 侧
        // 证书门弹“未导入证书”。
        Task {
            var appToLaunch = app
            do {
                // 0.2.44（F2）：熔断检查前置到验签之前——熔断的客直接干净失败，
                // 不再先花几十毫秒跑完整验签。熔断逻辑本身不动（分级在
                // SBDiagLogIsGuestStuckForGuest 里：slow 可重试，stuck 才拦）。
                if let stuckStep = SBInstaller.stuckStep(for: app) {
                    SBDiagLog.log("点图标：\(app.bundleID) 卡死熔断检查：熔断=是（步=\(stuckStep)），跳过验签直接干净失败")
                    await MainActor.run {
                        self.isLaunching = false
                        self.launchingBundleID = nil
                        self.activeAlert = CoordinatorAlert(
                            title: "启动失败",
                            message: "该应用上次打开时卡住了（\(stuckStep)），已跳过；重新导入或等后续版本可再试")
                    }
                    return
                }
                // 0.2.6：旧版本装的包先重打补丁 + 重签（patchRevision < 2 的
                // 包主可执行文件缺 LC_ID_DYLIB，dlopen 必败——0.2.5 真机实证）。
                // 重打失败直接弹错，不发启动请求；无证书时不重打（修不了），
                // 直接进签名门（门能拦 Team/结构，不依赖证书）。
                // 0.2.44（B-3）：重打补丁门再扩一个触发条件——主程序安装名
                // 不是期望唯一名（0.2.43 及以前装的包是裸 basename，Guoguo
                // 碰撞的根因）。patchRevision 已是当前值、但安装名仍是旧
                // 的包（例如 0.2.44 装完又被外部改过）同样触发重打补丁。
                // 0.2.45：再扩 rev 4 损坏指纹——主程序引用仍含
                // "@rpath/<bundleID>/" 前缀的包（0.2.44 打坏的 4 个客：
                // patchRevision 已是 4、主程序 ID 也是正确的唯一名，上面
                // 两道门都看不见），触发重打补丁＋逆向修复＋重签。
                if SBCertificate.hasCertificate,
                   app.patchRevision < SBConstants.patchRevision
                   || SBInstaller.installNameNeedsRepair(app)
                   || SBInstaller.namespaceNeedsRepair(app) {
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
                    // 0.2.12：未签名记录也记一行签名逐项——二进制可能带着旧
                    // 签名（安装时签名失败照装、或记录过期），逐项是判断它
                    // 能不能走 JIT 还是该重签的唯一依据；只记不拦，拦的活
                    // 仍由 Team 比对做。
                    SBDiagLog.log("签名修复门验签：\(appToLaunch.bundleID) \(appToLaunch.executableURL.path) \(SBInstaller.signatureDetailFields(at: appToLaunch.executableURL.path))")
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
                    self.launchingBundleID = nil
                    self.activeAlert = CoordinatorAlert(
                        title: "启动失败",
                        message: self.launchRepairErrorMessage(error))
                }
                return
            }
            // 无证书：跳过注入件重签，直接发启动请求（ObjC 侧证书门会弹
            // “未导入证书”并给去导入证书按钮）。
            guard SBCertificate.hasCertificate else {
                // 0.2.16：同下面 339 行——Swift 6 下 @Sendable 闭包不能捕获 var，
                // 先定格成 let 再进 MainActor.run。0.2.8 只修了下面那处，这处
                // 漏了；0.2.15 的 CI 上它还是警告，新 runner 镜像
                //（macos-26-arm64 20261112.0504.1，Xcode 同为 26.2）上它升成
                // 错误，Archive 步 exit 65。
                let launchTarget = appToLaunch
                await MainActor.run { self.launchGuestInProcess(app: launchTarget) }
                return
            // 注意：launchingBundleID 不在这里清——launchGuestInProcess 的
            // 完成回调里统一清（成功与失败都清），避免加载态提前消失。
            }
            // 0.2.8：Swift 6 下 @Sendable 闭包不能捕获 var——先把最终值
            // 定格成 let 再进 MainActor.run（0.2.8 第一轮 CI 红于此，
            // SBAppCoordinator.swift:309）。
            let launchTarget = appToLaunch
            let ok = await SBCertificate.ensureHooksDylibSigned()
            await MainActor.run {
                if ok {
                    self.launchGuestInProcess(app: launchTarget)
                } else {
                    // 0.2.10 报错日志：注入件签名失败之前只弹弹窗；失败
                    // 的具体原因（无证书/件不在/重签失败）由
                    // performEnsureHooksDylibSigned 记行，这里记弹窗决定。
                    // 0.2.19：文案统一走 SBCertificate.hooksSignFailureReason——
                    // 证书本身没问题（客应用用它签得好好的），不再让用户
                    // 重导证书背锅；具体原因见启动日志。
                    SBDiagLog.log("启动失败：\(launchTarget.bundleID) 注入组件签名失败，弹启动失败（\(SBCertificate.hooksSignFailureReason)）")
                    self.isLaunching = false
                    self.launchingBundleID = nil
                    self.activeAlert = CoordinatorAlert(
                        title: "启动失败",
                        message: SBCertificate.hooksSignFailureReason)
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

    /// 进程内加载（launchApp 的后半段，签名门通过后才进；0.2.27：不再请求重启）。
    /// 加载是同步的（dlopen→拦截→跳 main，hook 激活后 main 随即返回），
    /// 所以不再设 30 秒看门狗——主线程在加载期间被占用，同线程的计时器
    /// 在主线程阻塞时根本跑不起来，设了也触发不了。
    private func launchGuestInProcess(app: SBInstalledApp) {
        // 0.2.26 G7：LC 同款（LCAppModel.swift:403-408）——iOS 26+ 且客包带
        // Frameworks/MetalANGLE.framework/MetalANGLE 时，把该路径写进宿主
        // HOME/Library/preloadLibraries.txt（覆盖写一行）；新鲜进程在 main 里
        // 读它逐行 dlopen 后删文件；进程内路由 loadGuest 在 dlopen 前读它。
        // 只写 MetalANGLE 这一行，LC 同款。
        if #available(iOS 26, *) {
            let metalANGLE = app.bundleURL.appendingPathComponent("Frameworks/MetalANGLE.framework/MetalANGLE")
            if FileManager.default.fileExists(atPath: metalANGLE.path) {
                // homeDirectoryForCurrentUser 是 macOS 专属，iOS 上不可用；
                // documentsURL 即 $HOME/Documents，回推一级就是 HOME。
                let preloadPath = SBConstants.documentsURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("Library/preloadLibraries.txt")
                try? metalANGLE.path.write(toFile: preloadPath.path, atomically: true, encoding: .utf8)
                SBDiagLog.log("预加载：客带 MetalANGLE，写 preloadLibraries.txt")
            }
        }
        launchStage = "证书检查"
        SBGuestLoader.shared().requestGuestLaunch(
            withBundleID: app.bundleID,
            containerUUID: app.containerUUID,
            diskDirectoryName: app.diskDirectoryName,
            keychainGroup: app.keychainGroup
        ) { [weak self] error in
            guard let self = self else { return }
            self.launchStage = nil
            self.launchingBundleID = nil
            guard let error = error else {
                // 0.2.36：成功也要清旗——之前成功时直接 return，旗标永久为真，
                // 同进程内再点任何客都被 launchApp 的 guard 静默吞掉（0.2.35
                // 真机：Husk 首次打开成功后，再点开不了，只能重启进程冷启动）。
                self.isLaunching = false
                SBDiagLog.log("点图标：\(app.bundleID) 进程内加载完成，isLaunching 已清")
                return
            }
            self.isLaunching = false
            let stage = (error as NSError).userInfo[SBGuestLoaderErrorStageKey] as? String ?? "启动失败"
            // 0.2.10 报错日志：启动请求失败之前只弹弹窗；原因（证书门/
            // 包缺失/看门狗）已由 ObjC 侧记行，这里记弹窗决定。
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
        // 证书门与包检查已同步跑完：回调还没来 = 已通过证书门，进入加载阶段。
        // （证书失败 / 包缺失时回调是同步调的，上面已把 launchStage 置 nil，不会误推进。
        // 进程内加载本身也在 requestGuestLaunch 内同步完成——成功时客已在前台。）
        if launchStage != nil {
            launchStage = "进程内加载"
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

    /// 0.2.26 G6：LC 同款（LCSealBoxRootView.swift:147-162）——上次进程
    /// 未捕获异常（main.m 的处理器写的 SBLastLaunchError 键），进 UI 弹一次
    /// 并清掉；文案截短，详情见诊断日志。
    func showLastLaunchErrorIfNeeded() {
        guard let error = SBStore.shared.lastLaunchError else { return }
        SBStore.shared.lastLaunchError = nil
        let shown = error.count > 400 ? String(error.prefix(400)) + "…" : error
        SBDiagLog.log("上次启动异常弹窗：\(shown.prefix(120))，键已清")
        activeAlert = CoordinatorAlert(
            title: "上次启动崩溃",
            message: shown + "\n\n详情见诊断日志。")
    }

    /// 0.2.26 G9：LC 同款 SigningInProgress 崩溃检测——上次安装/重装中途
    /// 进程死了（signingInProgress 残留为真），报一次并清旗。
    func showSigningCrashIfNeeded() {
        guard SBStore.shared.signingInProgress else { return }
        SBStore.shared.signingInProgress = false
        SBDiagLog.log("上次安装中途崩溃弹窗：signingInProgress 残留，旗已清")
        activeAlert = CoordinatorAlert(
            title: "上次安装中途崩溃",
            message: "上次安装/重装中途应用崩溃了，安装可能没有完成。请检查应用是否已在桌面，没有的话重新导入。")
    }
}
