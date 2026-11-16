//
//  SettingsView.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — settings page (implementation #2).
//
//  Full-screen cover with a Done button top-right (the only exit — a
//  fullScreenCover has no swipe-to-dismiss). Four sections, no more:
//  certificate, JIT status, storage, about.
//
//  CERTIFICATE — this closes the half-open flow #1 left behind: the
//  certificate gate's "Go to Settings" only recorded
//  requestedSystemPage = .settings, and no p12 import UI existed. The
//  import here is real: pick a .p12 file, enter its password, verify
//  with LCUtils.getCertTeamId (nil = wrong certificate / password),
//  then write the same three keys the old settings page wrote —
//  LCCertificateData / LCCertificatePassword / LCCertificateUpdateDate
//  in the App Group defaults — which is exactly what
//  LCSharedUtils.certificatePassword() (and the LCBootstrap.m iOS 26+
//  hard gate) reads. On success the "SealBoxCertificateImported"
//  notification is posted so RootView's gate lets the desktop through;
//  the same notification is posted on removal so the gate closes again.
//  "验证证书" runs LCUtils.validateJITLessSetup (signs the TestJITLess
//  stub and checks the signature): it verifies the certificate +
//  signing chain, not JIT itself.
//
//  JIT — DISPLAY ONLY, and never the raw stored value. The old bug was
//  that a missing "LCJITEnablerType" key reads as 0 via integer(forKey:),
//  which happens to equal .SideJITServer, so a fresh install falsely
//  showed SideJITServer. Here the enabler name is shown ONLY when the
//  key actually exists (object(forKey:) != nil) and the raw value maps
//  to a known case — a stored 4 (the deleted .SideStore case) fails
//  the failable init and shows as "not recorded", never as another
//  enabler. JIT itself is a live probe (isJITEnabledNow, see
//  ControlCenter.swift), and the opening entry lives in Seal, never
//  here — there is no enabler picker.
//
//  STORAGE — LCStorageManagementModel, same model the old storage page
//  used; only the UI is new.
//
//  NOTE: this view uses ONE SwiftUI .alert (driven by a single enum)
//  and ONE .sheet (driven by a single enum). SwiftUI honours only one
//  alert / sheet per view — chaining several, as the old settings page
//  once did, silently drops all but one.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var sharedModel: SharedModel
    var onDone: (() -> Void)? = nil
    var onOpenSwitcher: (() -> Void)? = nil

    @StateObject private var storageModel = LCStorageManagementModel()

    // MARK: Certificate state

    @State private var certificateImported = LCUtils.certificateData() != nil
    /// -1 unknown, 0 valid, 1 revoked, 2 verification failed.
    @State private var certStatus = -1
    @State private var certValidUntil: String?
    @State private var certOrgUnit: String?
    @State private var certLastUpdate: String?
    @State private var isVerifying = false
    @State private var isImporting = false

    // MARK: JIT state

    @State private var jitEnabled = false

    // MARK: Import flow state

    @State private var pendingP12Data: Data?
    @State private var pendingP12Name: String?
    @State private var password = ""
    @State private var autoImportRequested = false
    @State private var windowScale: CGFloat = 1.0

    @State private var alertState: SettingsAlert?
    @State private var activeSheet: SettingsSheet?

    private enum SettingsAlert: Identifiable {
        case error(String)
        case success(String)
        case removeCertificate

        var id: String {
            switch self {
            case .error(let message): return "error:\(message)"
            case .success(let message): return "success:\(message)"
            case .removeCertificate: return "remove"
            }
        }
    }

    private enum SettingsSheet: Identifiable {
        case p12Picker
        case password

        var id: String {
            switch self {
            case .p12Picker: return "p12"
            case .password: return "password"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            List {
                certificateSection
                jitSection
                storageSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { done() }
                }
            }
        }
        .scaleEffect(windowScale)
        .overlay(alignment: .bottom) {
            HomeBarView(
                onReturnToDesktop: { done() },
                onOpenSwitcher: { onOpenSwitcher?() },
                windowScale: $windowScale
            )
        }
        .onAppear {
            refreshCertificateInfo()
            jitEnabled = isJITEnabledNow()
            Task {
                await storageModel.refresh(apps: sharedModel.apps, hiddenApps: sharedModel.hiddenApps)
            }
            // A "certificate" deep link (certificate gate / Seal) asks
            // for the import flow directly — open the picker once.
            if !autoImportRequested,
               sharedModel.requestedSystemPage == .settings,
               let link = sharedModel.deepLink, link.host == "certificate" {
                autoImportRequested = true
                sharedModel.deepLink = nil
                activeSheet = .p12Picker
            }
        }
        .alert(alertTitle, isPresented: Binding(
            get: { alertState != nil },
            set: { if !$0 { alertState = nil } }
        ), presenting: alertState) { state in
            switch state {
            case .error:
                Button("好", role: .cancel) {}
            case .success:
                Button("好", role: .cancel) {}
            case .removeCertificate:
                Button("移除证书", role: .destructive) {
                    Task { await removeCertificate() }
                }
                Button("取消", role: .cancel) {}
            }
        } message: { state in
            switch state {
            case .error(let message):
                Text(message)
            case .success(let message):
                Text(message)
            case .removeCertificate:
                Text("将删除已导入的证书与密码。此后客 App 在 iOS 26+ 上无法启动，直到重新导入证书。")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .p12Picker:
                P12DocumentPicker { url in
                    activeSheet = nil
                    pickP12(url: url)
                } onCancel: {
                    activeSheet = nil
                }
            case .password:
                p12PasswordSheet
            }
        }
    }

    private var alertTitle: String {
        switch alertState {
        case .error: return "错误"
        case .success: return "成功"
        case .removeCertificate: return "移除证书"
        case nil: return "设置"
        }
    }

    private func done() {
        sharedModel.requestedSystemPage = nil
        onDone?()
    }

    // MARK: - Certificate section

    private var certificateSection: some View {
        Section {
            HStack {
                Text("状态")
                Spacer()
                Text(certificateImported ? "已导入" : "未导入")
                    .foregroundStyle(certificateImported ? .green : .secondary)
            }
            if certificateImported {
                if let statusText = certificateStatusText {
                    HStack {
                        Text("证书状态")
                        Spacer()
                        Text(statusText)
                            .foregroundStyle(certStatus == 0 ? .green : .red)
                    }
                }
                if let validUntil = certValidUntil {
                    HStack {
                        Text("有效期至")
                        Spacer()
                        Text(validUntil)
                            .foregroundStyle(.secondary)
                    }
                }
                if let orgUnit = certOrgUnit {
                    HStack {
                        Text("组织单位")
                        Spacer()
                        Text(orgUnit)
                            .foregroundStyle(.secondary)
                    }
                }
                if let lastUpdate = certLastUpdate {
                    HStack {
                        Text("导入时间")
                        Spacer()
                        Text(lastUpdate)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button("导入证书 (.p12)") {
                activeSheet = .p12Picker
            }
            .disabled(isImporting)
            if certificateImported {
                Button("验证证书") {
                    Task { await verifyCertificate() }
                }
                .disabled(isVerifying)
                Button("移除证书", role: .destructive) {
                    alertState = .removeCertificate
                }
            }
        } header: {
            Text("证书")
        } footer: {
            Text("没有证书时，iOS 26+ 上客 App 连启动入口都进不去（JIT-less 重签也需要它）。证书来自你自己的开发者账号（.p12 + 密码），免费账号证书 7 天过期，需重新导入。")
        }
    }

    private var certificateStatusText: String? {
        guard certificateImported, certStatus != -1 else { return nil }
        switch certStatus {
        case 0: return "有效"
        case 1: return "已被吊销"
        default: return "验证失败"
        }
    }

    private var p12PasswordSheet: some View {
        NavigationView {
            VStack(spacing: 16) {
                if let name = pendingP12Name {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                SecureField("证书密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                Button("导入") {
                    activeSheet = nil
                    Task { await confirmImport() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty || isImporting)
                Button("取消") {
                    activeSheet = nil
                    pendingP12Data = nil
                    pendingP12Name = nil
                    password = ""
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(24)
            .navigationTitle("输入证书密码")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetentsIfAvailable()
    }

    // MARK: - Certificate import (the closed loop)

    private func pickP12(url: URL) {
        // The picker copies the file (asCopy: true); read it directly,
        // falling back to a security-scoped read if that fails.
        var data = try? Data(contentsOf: url)
        if data == nil {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            data = try? Data(contentsOf: url)
        }
        guard let p12Data = data else {
            alertState = .error("无法读取证书文件。")
            return
        }
        pendingP12Data = p12Data
        pendingP12Name = url.lastPathComponent
        password = ""
        activeSheet = .password
    }

    private func confirmImport() async {
        guard let p12Data = pendingP12Data else { return }
        let certPassword = password
        password = ""
        isImporting = true
        defer { isImporting = false }

        // Wrong certificate / password → nil. This is the same check
        // the old settings page used; it loads ZSign, so it runs here
        // on the main actor exactly as before.
        guard LCUtils.getCertTeamId(withKeyData: p12Data, password: certPassword) != nil else {
            alertState = .error("证书或密码不正确，请检查 .p12 文件与密码。")
            return
        }

        // The three keys the bootstrap gate and the signer read.
        LCUtils.appGroupUserDefault.set(p12Data, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(certPassword, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(Date.now, forKey: "LCCertificateUpdateDate")
        UserDefaults.standard.set(LCSharedUtils.appGroupID(), forKey: "LCAppGroupID")

        pendingP12Data = nil
        pendingP12Name = nil
        certificateImported = true
        // Expiry + org unit are filled by refreshCertificateInfo() below
        // (validateCertificate via ZSigner). The direct p12 helper was
        // removed: its SecCertificate APIs are not declared for iOS
        // in this SDK, so it could not compile.
        refreshCertificateInfo()
        // Let RootView's gate through (and re-check on next activation).
        NotificationCenter.default.post(name: Notification.Name("SealBoxCertificateImported"), object: nil)
        alertState = .success("证书已导入，客 App 现在可以启动了。")
    }

    private func removeCertificate() async {
        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificateUpdateDate")
        UserDefaults.standard.set(nil, forKey: "LCAppGroupID")
        certificateImported = false
        certStatus = -1
        certValidUntil = nil
        certOrgUnit = nil
        certLastUpdate = nil
        // The gate closes again: RootView re-reads the certificate on
        // this notification.
        NotificationCenter.default.post(name: Notification.Name("SealBoxCertificateImported"), object: nil)
    }

    private func refreshCertificateInfo() {
        certificateImported = LCUtils.certificateData() != nil
        if let lastUpdate = LCUtils.appGroupUserDefault.object(forKey: "LCCertificateUpdateDate") as? Date {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            certLastUpdate = formatter.string(from: lastUpdate)
        } else {
            certLastUpdate = nil
        }
        certStatus = -1
        certValidUntil = nil
        certOrgUnit = nil
        guard certificateImported else { return }
        _ = LCUtils.validateCertificate { status, date, ou, error in
            DispatchQueue.main.async {
                if let error {
                    certStatus = 2
                    alertState = .error(error)
                    return
                }
                certStatus = Int(status)
                if let date {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .short
                    formatter.timeStyle = .medium
                    certValidUntil = formatter.string(from: date)
                }
                if let ou {
                    certOrgUnit = ou
                }
            }
        }
    }

    private func verifyCertificate() async {
        guard certificateImported else { return }
        isVerifying = true
        defer { isVerifying = false }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            LCUtils.validateJITLessSetup { success, error in
                if success {
                    alertState = .success("证书可用，签名链验证通过。")
                } else {
                    alertState = .error(error?.localizedDescription ?? "证书验证失败。")
                }
                continuation.resume()
            }
        }
    }

    // MARK: - JIT section (display only)

    private var jitSection: some View {
        Section {
            HStack {
                Text("当前状态")
                Spacer()
                Text(jitEnabled ? "已开启" : "已关闭")
                    .foregroundStyle(jitEnabled ? .green : .secondary)
            }
            HStack {
                Text("开启器")
                Spacer()
                Text(jitEnablerText)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("JIT")
        } footer: {
            Text("JIT 由 Seal 开启，SealBox 只显示当前状态，不提供开启入口。普通应用走 JIT-less 重签，不需要 JIT；只有模拟器等少数应用需要 JIT。")
        }
    }

    /// The recorded enabler — shown ONLY when the key really exists
    /// and maps to a known case. A missing key must never read as
    /// .SideJITServer (the old integer(forKey:) = 0 bug), and the
    /// deleted .SideStore raw value (4) must never map to another
    /// enabler: both fall through to "未记录".
    private var jitEnablerText: String {
        guard let raw = LCUtils.appGroupUserDefault.object(forKey: "LCJITEnablerType") as? Int,
              let enabler = JITEnablerType(rawValue: raw) else {
            return "未记录"
        }
        return enabler.displayName
    }

    // MARK: - Storage section

    private var storageSection: some View {
        Section {
            if storageModel.isCalculating {
                HStack {
                    ProgressView()
                    Text("正在统计…")
                        .foregroundStyle(.secondary)
                }
            } else if let breakdown = storageModel.breakdown {
                storageRow("总计", size: breakdown.totalSize)
                storageRow("应用本体", size: breakdown.appBundleSize)
                storageRow("应用数据", size: breakdown.containersSize)
                storageRow("临时文件", size: breakdown.temporaryFilesSize)
                storageRow("应用组", size: breakdown.appGroupSize)
                storageRow("插件", size: breakdown.tweaksSize)
                storageRow("其他", size: breakdown.otherSize)
                ForEach(breakdown.appItems) { item in
                    HStack {
                        Text(item.appModel.displayName)
                            .lineLimit(1)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: item.totalSize, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let error = storageModel.errorInfo {
                Text(error)
                    .foregroundStyle(.red)
            }
            Button("重新统计") {
                Task {
                    await storageModel.refresh(apps: sharedModel.apps, hiddenApps: sharedModel.hiddenApps)
                }
            }
        } header: {
            Text("存储")
        }
    }

    private func storageRow(_ title: String, size: Int64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - About section

    private var aboutSection: some View {
        Section {
            NavigationLink("关于 SealBox") {
                AboutView()
            }
        }
    }
}

// MARK: - .p12 document picker (install entry for certificates)

private struct P12DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.p12], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPick(url)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
