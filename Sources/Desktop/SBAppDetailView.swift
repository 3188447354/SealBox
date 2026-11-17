// 应用详情页：信息展示、重命名（显示名覆盖）、删除此 App。
import SwiftUI

/// 应用详情页。删除只负责确认 sheet 与回调，真删由调用方注入的 onDeleteApp 执行；
/// 删失败时调用方把错误回传（deleteError），本页只展示，不动桌面。
struct SBAppDetailView: View {
    let app: SBInstalledApp
    var onDeleteApp: ((SBInstalledApp) -> Void)?
    var onClose: (() -> Void)?
    /// 调用方回传的删除失败错误（SBError 中文 message），有值时只弹错。
    var deleteError: Error?

    @State private var showingDeleteConfirm: Bool = false
    @State private var showingRename: Bool = false
    @State private var newDisplayName: String = ""
    @State private var showingDeleteError: Bool = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    SBDesktopCell(app: app, iconSize: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName)
                            .font(.system(size: 20, weight: .semibold))
                        Text(app.bundleID)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("信息") {
                detailRow(title: "显示名", value: displayName)
                detailRow(title: "Bundle ID", value: app.bundleID)
                detailRow(title: "版本", value: "\(app.version)（\(app.shortVersion)）")
                detailRow(title: "大小", value: formattedSize)
                detailRow(title: "安装日期", value: dateText(app.installedDate))
                detailRow(title: "容器数", value: "\(containerCount)")
                detailRow(title: "签名", value: app.signed ? "已签名" : "未签名")
                detailRow(title: "JIT", value: app.needsJIT ? "需要 JIT" : "不需要 JIT")
                if let result = app.lastLaunchResult {
                    detailRow(title: "上次启动", value: result.success ? "成功" : "失败")
                    if !result.message.isEmpty {
                        detailRow(title: "启动结果", value: result.message)
                    }
                    detailRow(title: "启动时间", value: dateText(result.date))
                } else {
                    detailRow(title: "上次启动", value: "暂无记录")
                }
            }

            Section {
                Button("重命名") { showingRename = true }
                Button("删除此 App") { showingDeleteConfirm = true }
                    .foregroundColor(.red)
            }
        }
        .navigationTitle("应用详情")
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除此 App", isPresented: $showingDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                onDeleteApp?(app)
            }
        } message: {
            Text("将删除 App 本体、全部数据与钥匙串记录，此操作不可撤销")
        }
        .alert("重命名", isPresented: $showingRename) {
            TextField("显示名", text: $newDisplayName)
            Button("取消", role: .cancel) {}
            Button("保存") { saveRename() }
        } message: {
            Text("只改桌面显示名，不改 App 本体")
        }
        .alert("删除失败", isPresented: $showingDeleteError) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(deleteError?.localizedDescription ?? "删除失败，请重试")
        }
        .onAppear { newDisplayName = displayName }
        .onChange(of: deleteError?.localizedDescription) { _ in
            showingDeleteError = deleteError != nil
        }
    }

    private var displayName: String {
        let suite = "group." + (Bundle.main.bundleIdentifier ?? "")
        let overrides = UserDefaults(suiteName: suite)?.dictionary(forKey: "SBDisplayNameOverrides") as? [String: String]
        return overrides?[app.bundleID] ?? app.displayName
    }

    private var formattedSize: String {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return "未知"
        }
        let appURL = documents.appendingPathComponent("Applications").appendingPathComponent(app.bundleID + ".app")
        var total: UInt64 = 0
        if let enumerator = FileManager.default.enumerator(at: appURL, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in enumerator {
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += UInt64(size)
                }
            }
        }
        if total == 0, let size = try? FileManager.default.attributesOfItem(atPath: appURL.path)[.size] as? UInt64 {
            total = size
        }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    private var containerCount: Int {
        // 容器以 containerUUID 计：有值计 1，无值计 0；多容器形态由 GuestLoader 侧维护。
        app.containerUUID.isEmpty ? 0 : 1
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundColor(.secondary)
            Spacer()
            Text(value).lineLimit(1)
        }
        .font(.system(size: 15))
    }

    /// 重命名只改显示名覆盖 SBDisplayNameOverrides，不动 App 本体与 Bundle ID。
    private func saveRename() {
        let name = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let suite = "group." + (Bundle.main.bundleIdentifier ?? "")
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        var overrides = defaults.dictionary(forKey: "SBDisplayNameOverrides") as? [String: String] ?? [:]
        overrides[app.bundleID] = name
        defaults.set(overrides, forKey: "SBDisplayNameOverrides")
    }
}
