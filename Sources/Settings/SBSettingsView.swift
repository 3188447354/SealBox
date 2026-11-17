// SBSettingsView.swift — 设置页：证书、JIT 状态、存储用量与关于（含诚实边界说明）。

import SwiftUI
import UIKit

/// 设置页（SwiftUI，iOS 15）。
///
/// 注入方式：初始化时传入 `apps: [SBInstalledApp]` 与 `jitEnabled: Bool`，
/// 本页不直接依赖 SBStore 的实现细节；apps 与 jitEnabled 是传入时的快照，
/// 安装/卸载后宿主重新创建本页即可刷新。
/// 本页不包 NavigationView，由宿主放在导航栈里推入（标题为“设置”）。
public struct SBSettingsView: View {

    // MARK: - 注入

    public let apps: [SBInstalledApp]
    public let jitEnabled: Bool

    public init(apps: [SBInstalledApp], jitEnabled: Bool) {
        self.apps = apps
        self.jitEnabled = jitEnabled
    }

    // MARK: - 状态

    @State private var certificateStatus: String = SBCertificate.statusText
    @State private var hasCertificateFlag: Bool = SBCertificate.hasCertificate
    @State private var isSelfTesting = false
    @State private var appSizes: [String: Int64] = [:]
    @State private var activeAlert: ActiveAlert?
    @State private var toastMessage: String?

    // MARK: - 页面

    public var body: some View {
        List {
            certificateSection
            jitSection
            storageSection
            aboutSection
        }
        .navigationTitle("设置")
        .onAppear {
            refreshCertificateState()
            computeSizes()
        }
        .alert(item: $activeAlert) { item in
            switch item {
            case .message(let title, let message):
                return Alert(
                    title: Text(title),
                    message: Text(message),
                    dismissButton: .default(Text("知道了"))
                )
            case .certificateDeleted:
                return Alert(
                    title: Text("证书已被删除"),
                    message: Text("证书已被删除，请重新导入证书"),
                    primaryButton: .default(Text("去导入")) { startImport() },
                    secondaryButton: .cancel(Text("稍后"))
                )
            case .confirmDelete:
                return Alert(
                    title: Text("删除证书"),
                    message: Text("删除后需要重新导入证书才能安装与启动客 App，确定删除吗？"),
                    primaryButton: .destructive(Text("删除")) { deleteCertificate() },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let toastMessage = toastMessage {
                Text(toastMessage)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(UIColor.systemGray))
                    .foregroundColor(.white)
                    .cornerRadius(20)
                    .padding(.bottom, 24)
            }
        }
        .animation(.easeInOut, value: toastMessage)
    }

    // MARK: - 证书

    private var certificateSection: some View {
        Section(header: Text("证书")) {
            HStack(alignment: .top) {
                Text("状态")
                Spacer()
                Text(certificateStatus)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if !hasCertificateFlag {
                Text("未导入证书时无法安装与启动客 App，请先导入证书。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Button("导入证书") {
                startImport()
            }
            Button("删除证书") {
                activeAlert = .confirmDelete
            }
            .foregroundColor(.red)
            .disabled(!hasCertificateFlag)
            Button(isSelfTesting ? "自测中…" : "启动链自测") {
                runSelfTest()
            }
            .disabled(isSelfTesting || !hasCertificateFlag)
        }
    }

    // MARK: - JIT 状态（只展示）

    private var jitSection: some View {
        Section(header: Text("JIT 状态"), footer: Text("开启入口在 Seal 侧")) {
            HStack {
                Text("JIT")
                Spacer()
                Text(jitEnabled ? "完整 JIT·由 Seal 开启" : "已关闭")
                    .foregroundColor(jitEnabled ? .green : .secondary)
            }
        }
    }

    // MARK: - 存储用量（按 bundle 目录实算）

    private var storageSection: some View {
        Section(header: Text("存储用量")) {
            HStack {
                Text("已装应用合计")
                Spacer()
                Text(totalSizeText)
                    .foregroundColor(.secondary)
            }
            if apps.isEmpty {
                Text("暂无已安装应用")
                    .foregroundColor(.secondary)
            } else {
                ForEach(apps.indices, id: \.self) { index in
                    let app = apps[index]
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.displayName)
                            Text(app.version)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(sizeText(for: app))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 关于（诚实边界全文）

    private var aboutSection: some View {
        Section(header: Text("关于")) {
            Text(aboutText)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    /// 关于页诚实边界全文：以下每一点都如实写出，不夸大、不省略。
    private var aboutText: String {
        "Sealbox 不是真正的沙盒：容器不隔离，客 App 与宿主共用同一套文件与数据；权限全局共享，客 App 能使用宿主已经获得的权限。权限声明（entitlement）只用宿主的，客 App 自带的权限声明不会生效。\n\n" +
        "远程推送不工作，扩展（Extension）不支持。\n\n" +
        "宿主应用本身须用开发证书签名后才能安装使用；免费证书 7 天过期，过期后需要重新导入证书并重新签名。iOS 26 及以上系统没有证书就启动不了客 App。\n\n" +
        "不承诺所有 IPA 都能跑：部分应用可能闪退、功能缺失或完全无法启动。"
    }

    // MARK: - 证书操作

    /// 刷新证书状态：先读缓存文案立即显示，再异步校验刷新；同时检查证书是否被外部删掉。
    private func refreshCertificateState() {
        hasCertificateFlag = SBCertificate.hasCertificate
        certificateStatus = SBCertificate.statusText
        Task { @MainActor in
            certificateStatus = await SBCertificate.refreshStatusText()
            hasCertificateFlag = SBCertificate.hasCertificate
        }
        if !SBCertificate.checkStillExists() {
            activeAlert = .certificateDeleted
        }
    }

    /// 导入证书：取最上层视图控制器当 presenter；用户取消静默处理，不弹任何提示。
    private func startImport() {
        guard let presenter = Self.topViewController() else {
            activeAlert = .message(title: "导入失败", message: "暂时打不开文件选择器，请重试")
            return
        }
        Task { @MainActor in
            do {
                try await SBCertificate.importP12(presenter: presenter)
                certificateStatus = await SBCertificate.refreshStatusText()
                hasCertificateFlag = SBCertificate.hasCertificate
                showToast("证书导入成功")
            } catch let error as SBError {
                if case SBError.cancelled = error {
                    return
                }
                activeAlert = .message(title: "导入失败", message: error.localizedDescription)
            } catch {
                activeAlert = .message(title: "导入失败", message: error.localizedDescription)
            }
        }
    }

    private func deleteCertificate() {
        do {
            try SBCertificate.deleteCertificate()
            certificateStatus = SBCertificate.statusText
            hasCertificateFlag = SBCertificate.hasCertificate
            showToast("证书已删除")
        } catch {
            activeAlert = .message(title: "删除失败", message: error.localizedDescription)
        }
    }

    /// 跑启动链自测：成功 toast「自测通过」，失败按阶段弹错。
    private func runSelfTest() {
        isSelfTesting = true
        Task { @MainActor in
            let result = await SBCertificate.runChainSelfTest()
            isSelfTesting = false
            switch result {
            case .success:
                showToast("自测通过")
            case .failure(let error):
                activeAlert = .message(title: "自测失败", message: "\(error.stage)：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 存储用量计算

    private var totalSizeText: String {
        if apps.isEmpty {
            return Self.formattedSize(0)
        }
        guard appSizes.count >= apps.count else {
            return "计算中…"
        }
        let total = apps.reduce(Int64(0)) { $0 + (appSizes[$1.diskDirectoryName] ?? 0) }
        return Self.formattedSize(total)
    }

    private func sizeText(for app: SBInstalledApp) -> String {
        guard let size = appSizes[app.diskDirectoryName] else {
            return "计算中…"
        }
        return Self.formattedSize(size)
    }

    /// 后台逐个实算 bundle 目录大小（按 diskDirectoryName 索引，平行安装同 Bundle ID 不串台）。
    private func computeSizes() {
        let apps = apps
        Task.detached(priority: .utility) {
            var result: [String: Int64] = [:]
            for app in apps {
                result[app.diskDirectoryName] = Self.directoryByteSize(app.bundleURL)
            }
            await MainActor.run {
                self.appSizes = result
            }
        }
    }

    /// 递归统计目录下全部文件的字节总数（跳过隐藏文件，不跟符号链接）。
    private static func directoryByteSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory != true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - 杂项

    /// 最上层视图控制器（沿 presentedViewController 链走到顶），供导入证书 present 选择器用。
    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        guard let root = windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return nil
        }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    private func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

    /// 弹窗种类：普通提示 / 证书被删引导重导 / 删除前确认。单例 alert，避免多个 .alert 冲突。
    private enum ActiveAlert: Identifiable {
        case message(title: String, message: String)
        case certificateDeleted
        case confirmDelete

        var id: String {
            switch self {
            case .message(let title, let message):
                return "message-\(title)-\(message)"
            case .certificateDeleted:
                return "certificateDeleted"
            case .confirmDelete:
                return "confirmDelete"
            }
        }
    }
}
