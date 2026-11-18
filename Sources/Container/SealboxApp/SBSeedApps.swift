// SBSeedApps.swift — 随包预装的种子应用（0.2.1：Via 浏览器）。
//
// 首次启动时后台跑一次：把包内 IPA 拷到 Documents/IPAs 再走现有安装管线
// （解析 → 同名三选一 → 安装），装完出现在桌面第 2 页。
// 幂等：已装 com.tuyafeng.Via 或旗已置位就不再装；用户删了之后旗还在，
// 不再自动补。失败不置旗（下次启动重试，安装管线已弹错），成功才置旗。
// 绝不摆假图标：没装进 SBStore 就没有桌面记录。

import Foundation

enum SBSeedApps {
    static let viaBundleID = "com.tuyafeng.Via"
    static let viaFileName = "Via-1.9.0.ipa"

    /// 种子安装入口：不阻塞启动，调用方放后台 Task 里跑。
    static func installIfNeeded(coordinator: SBAppCoordinator) async {
        guard !SBStore.shared.seedViaInstalled else {
            SBDiagLog.log("种子安装：已装过，跳过")
            return
        }
        if SBStore.shared.app(with: viaBundleID) != nil {
            SBStore.shared.seedViaInstalled = true
            SBDiagLog.log("种子安装：Via 已在桌面，跳过")
            return
        }
        SBDiagLog.log("种子安装开始：Via")
        guard !coordinator.isInstalling else { return }
        guard let bundleURL = seedIPAURL() else { return }
        let destination = SBConstants.documentsURL
            .appendingPathComponent("IPAs", isDirectory: true)
            .appendingPathComponent(viaFileName)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: bundleURL, to: destination)
            }
        } catch {
            await MainActor.run {
                coordinator.activeAlert = SBAppCoordinator.CoordinatorAlert(
                    title: "安装失败", message: "准备 Via 安装文件失败，请重试")
            }
            return
        }
        await coordinator.installIPA(at: destination, displayNameHint: "Via")
        // installIPA 返回时安装已结束（成功或失败）：记录入库了才置旗。
        if SBStore.shared.app(with: viaBundleID) != nil {
            SBStore.shared.seedViaInstalled = true
            SBDiagLog.log("种子安装完成：Via 已上桌面")
        } else {
            SBDiagLog.log("种子安装失败：下次启动重试")
        }
    }

    /// 包内 IPA 的位置：资源进包时落在根目录；SeedApps 子目录是后备。
    private static func seedIPAURL() -> URL? {
        if let url = Bundle.main.url(forResource: "Via-1.9.0", withExtension: "ipa") {
            return url
        }
        return Bundle.main.url(
            forResource: "Via-1.9.0", withExtension: "ipa", subdirectory: "SeedApps")
    }
}
