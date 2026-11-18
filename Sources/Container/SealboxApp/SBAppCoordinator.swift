import SwiftUI
import UIKit

/// 桌面与各模块之间的接线：导入、启动、删除、设置、证书、收据弹错。
/// 桌面只管 UI 与手势，真实动作都在这里；GuestLoader 的证书门与看门狗在 ObjC 侧。
final class SBAppCoordinator: ObservableObject {

    struct CoordinatorAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    struct DuplicatePending: Identifiable {
        let id = UUID()
        let parsed: SBParsedIPA
        let existing: SBInstalledApp
    }

    @Published var installProgress = SBInstallProgress()
    @Published var isInstalling = false
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
                let parsed = try SBIPAParser.parse(ipaURL: url)
                if let existing = SBStore.shared.app(with: parsed.bundleID) {
                    await MainActor.run {
                        duplicatePending = DuplicatePending(parsed: parsed, existing: existing)
                    }
                    return
                }
                await runInstall(parsed: parsed, existing: nil)
            } catch {
                // 用户取消静默处理（C1 的一部分），其余弹错。
                if case SBError.cancelled = error { return }
                await MainActor.run {
                    activeAlert = CoordinatorAlert(title: "导入失败", message: error.localizedDescription)
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

    /// 真安装：进度每 100ms 刷一次到桌面 pill；装完把新应用追加到桌面顺序末尾。
    private func runInstall(parsed: SBParsedIPA, existing: SBInstalledApp?) async {
        await MainActor.run {
            isInstalling = true
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
                isInstalling = false
            }
        } catch {
            poll.cancel()
            await MainActor.run {
                installProgress.isInstalling = false
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

    /// 点图标后的真实启动：证书门与 5 秒看门狗在 GuestLoader 侧，失败回调里弹错。
    /// 另加 30 秒后备计时（F5）：从点图标起算，30 秒内无完成回调（进程未死、
    /// 无错误回调）则按当前阶段弹“启动超时（卡在：<阶段>），请重试”，超时后阶段清零。
    func launchApp(_ app: SBInstalledApp) {
        launchWatchdog?.cancel()
        launchWatchdog = nil
        launchStage = "证书检查"
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let stage = self.launchStage ?? "重启请求"
            self.launchStage = nil
            self.launchWatchdog = nil
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
            let stage = (error as NSError).userInfo[SBGuestLoaderErrorStageKey] as? String ?? "启动失败"
            Task { @MainActor in
                self.activeAlert = CoordinatorAlert(title: stage, message: error.localizedDescription)
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
        activeAlert = CoordinatorAlert(title: "启动失败", message: message)
    }
}
