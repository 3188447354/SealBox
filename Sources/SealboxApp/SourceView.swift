import SwiftUI
import Foundation
import UIKit

// Software source app (0.1.4): browse the 27 catalog apps, download their
// IPA into Documents/IPAs, and open installed apps' detail pages.
// Navigation: NavigationStack with large title + search; category chips
// filter the list; no tappable control sits in the bottom 28pt
// (the root view's swipe-up-home zone lives there).
// SwiftUI + Foundation only, no App Group, no LiveContainer/SealBox code.
// The only networking is the IPA download itself.

/// Downloads IPA files from the software source into Documents/IPAs.
///
/// Threading (Swift 6): URLSession calls its delegate on a private serial
/// queue, so every @Published update hops to the main actor via
/// Task { @MainActor }. The delegate-queue code itself only touches the file
/// system and the immutable catalog. The class is @unchecked Sendable for
/// that reason: its mutable state is only ever read/written on the main
/// actor (download() is called from UI actions).
final class DownloadManager: NSObject, URLSessionDownloadDelegate, ObservableObject, @unchecked Sendable {
    /// Download progress per app name, 0.0...1.0.
    @Published private(set) var progress: [String: Double] = [:]
    /// Names currently downloading.
    @Published private(set) var downloading: Set<String> = []

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    /// Shared state, set on each download call (main thread only) and only
    /// read back on the main actor once a download finishes.
    private weak var coordinator: SBAppCoordinator?

    /// Start downloading an app's IPA. No-op if it is already downloading
    /// or already installed; installing in progress is refused silently
    ///（0.2.37：导入不弹提示，桌面安装 pill 已在显示进度）。
    func download(_ app: SourceApp, coordinator: SBAppCoordinator) {
        guard !downloading.contains(app.name) else { return }
        self.coordinator = coordinator
        if coordinator.isInstalling {
            SBDiagLog.log("软件源下载：正在安装，忽略 \(app.name) 的下载请求")
            return
        }
        if Self.isInstalled(app) { return }
        let task = session.downloadTask(with: app.url)
        task.taskDescription = app.name
        downloading.insert(app.name)
        progress[app.name] = 0
        task.resume()
    }

    /// 单源头 SBStore 的“已安装”判断：原始 IPA 文件名对上，或显示名对上。
    static func isInstalled(_ app: SourceApp) -> Bool {
        return installedRecord(for: app) != nil
    }

    static func installedRecord(for app: SourceApp) -> SBInstalledApp? {
        let fileName = app.url.lastPathComponent
        return SBStore.shared.installedApps.first { record in
            record.sourceIPAFileName == fileName || record.displayName == app.name
        }
    }

    // MARK: - URLSessionDownloadDelegate (called on the session's queue)

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0,
              let name = downloadTask.taskDescription else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak self] in
            self?.progress[name] = fraction
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let name = downloadTask.taskDescription,
              let app = SourceCatalog.all.first(where: { $0.name == name }) else {
            // 0.2.37：下载完了却找不到对应应用，只记日志不弹错（按钮变回“获取”，
            // 用户可重试；导入全程不弹提示，MJ 22:35）。
            Task { @MainActor in
                SBDiagLog.log("软件源下载失败：下载完成但找不到对应的应用")
            }
            return
        }
        do {
            let destination = try Self.ipasDirectory()
                .appendingPathComponent(app.url.lastPathComponent)
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloading.remove(name)
                self.progress.removeValue(forKey: name)
                // 下载完成即走安装闭环：解析 → 同名三选一 → 安装管线。
                // 原始 IPA 留在 Documents/IPAs（重装的源文件，不删）。
                await self.coordinator?.installIPA(at: destination, displayNameHint: name)
            }
        } catch {
            // 0.2.37：下载完了文件没落位，只记日志不弹错（按钮变回“获取”，
            // 用户可重试；导入全程不弹提示，MJ 22:35）。
            Task { @MainActor [weak self] in
                self?.downloading.remove(name)
                self?.progress.removeValue(forKey: name)
                SBDiagLog.log("软件源下载失败：下载完成，保存文件失败")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error, let name = task.taskDescription else { return }
        // 0.2.37：网络失败只记日志不弹错（按钮变回“获取”，用户可重试；
        // 导入全程不弹提示，MJ 22:35）。
        Task { @MainActor [weak self] in
            self?.downloading.remove(name)
            self?.progress.removeValue(forKey: name)
            SBDiagLog.log("软件源下载失败：\(name) \(error.localizedDescription)")
        }
    }

    /// Documents/IPAs, creating it on first use.
    private static func ipasDirectory() throws -> URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dir = docs.appendingPathComponent("IPAs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Source list

struct SourceView: View {
    @StateObject private var downloads = DownloadManager()
    @State private var searchText = ""
    @State private var selectedCategory: SourceCategory = .all

    private var filteredApps: [SourceApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return SourceCatalog.all.filter { app in
            (selectedCategory == .all || app.category == selectedCategory)
                && (query.isEmpty || app.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                categoryChips
                List {
                    if filteredApps.isEmpty {
                        Text("没有找到结果")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filteredApps) { app in
                        NavigationLink {
                            SourceAppDetailView(app: app, downloads: downloads)
                        } label: {
                            SourceRow(app: app, downloads: downloads)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
            }
            .navigationTitle("软件源")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "搜索应用")
        }
    }

    /// Horizontally scrolling single-select category chips.
    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SourceCategory.allCases, id: \.self) { category in
                    Button {
                        selectedCategory = category
                    } label: {
                        Text(category.rawValue)
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                selectedCategory == category
                                    ? Color.accentColor
                                    : Color(.secondarySystemBackground),
                                in: Capsule()
                            )
                            .foregroundStyle(selectedCategory == category ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}

/// One row: first-character icon tile, name, intro, version, 获取 button.
private struct SourceRow: View {
    let app: SourceApp
    @ObservedObject var downloads: DownloadManager

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(name: app.name, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.headline)
                Text(app.intro)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(app.version)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            GetButtonView(app: app, downloads: downloads)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Source detail

struct SourceAppDetailView: View {
    let app: SourceApp
    @ObservedObject var downloads: DownloadManager
    @ObservedObject private var store = SBStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                AppIconView(name: app.name, size: 96)
                    .padding(.top, 12)
                VStack(spacing: 6) {
                    Text(app.name)
                        .font(.title2.bold())
                    Text(app.intro)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                GetButtonView(app: app, wide: true, downloads: downloads)
                    .padding(.horizontal, 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("版本说明")
                        .font(.headline)
                        .padding(.bottom, 10)
                    infoRow(label: "版本号", value: app.version)
                    Divider()
                        .padding(.vertical, 8)
                    infoRow(label: "更新日期", value: app.date)
                    Divider()
                        .padding(.vertical, 8)
                    infoRow(label: "分类", value: app.category.rawValue)
                    Divider()
                        .padding(.vertical, 8)
                    infoRow(label: "介绍", value: app.intro)
                    // Real disk size, only when the IPA is actually on disk.
                    if DownloadManager.isInstalled(app),
                       let size = VMFiles.ipaFileSizeString(fileName: app.url.lastPathComponent) {
                        Divider()
                            .padding(.vertical, 8)
                        infoRow(label: "文件大小", value: size)
                    }
                    // 已装记录的签名状态（装完才有；未装不显示该行）。
                    if let record = DownloadManager.installedRecord(for: app) {
                        Divider()
                            .padding(.vertical, 8)
                        infoRow(label: "签名状态", value: record.signed ? "已签名" : "未签名 / JIT 启动")
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Installed app detail

/// Detail page for an installed guest app (opened from the home screen
/// via VMApp.installed, payload = SBStore recordID UUID string).
/// Single source of truth: SBStore.shared.installedApps.
struct InstalledAppDetailView: View {
    let recordID: String
    @EnvironmentObject private var vm: VMState
    @EnvironmentObject private var coordinator: SBAppCoordinator
    @ObservedObject private var store = SBStore.shared
    @State private var showDeleteConfirm = false

    private var app: SBInstalledApp? {
        store.installedApps.first { $0.recordID.uuidString == recordID }
    }

    /// 包还在磁盘上吗（迁移建了记录、包被删了时为 false，给“重新安装”）。
    private var packageExists: Bool {
        guard let app = app, !app.diskDirectoryName.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: app.bundleURL.path)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let app = app {
                    ScrollView {
                        VStack(spacing: 20) {
                            InstalledAppIconView(app: app, size: 96)
                                .padding(.top, 12)
                                .opacity(app.needsReimport ? 0.45 : 1.0)
                            VStack(spacing: 6) {
                                Text(store.displayName(for: app))
                                    .font(.title2.bold())
                                if let catalogApp = SourceCatalog.all.first(where: { $0.name == app.displayName }) {
                                    Text(catalogApp.intro)
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                if app.needsReimport {
                                    Text("需重新导入")
                                        .font(.subheadline)
                                        .foregroundStyle(.orange)
                                }
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                infoRow(label: "版本号", value: app.version)
                                if !app.bundleID.isEmpty {
                                    Divider()
                                        .padding(.vertical, 8)
                                    infoRow(label: "Bundle ID", value: app.bundleID)
                                }
                                Divider()
                                    .padding(.vertical, 8)
                                infoRow(label: "签名状态", value: app.signed ? "已签名" : "未签名 / JIT 启动")
                                // 上次启动结果：有记录才显示该行。
                                if let last = app.lastLaunchResult {
                                    Divider()
                                        .padding(.vertical, 8)
                                    infoRow(
                                        label: "上次启动结果",
                                        value: "\(VMTime.dateTimeString(for: last.date)) \(last.message)")
                                }
                                // 文件大小：已装包在磁盘上的实测大小；包不在不显示该行。
                                if let size = VMFiles.directorySizeString(url: app.bundleURL) {
                                    Divider()
                                        .padding(.vertical, 8)
                                    infoRow(label: "文件大小", value: size)
                                }
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            if app.needsReimport {
                                // 占位记录只给两个按钮，不调启动。
                                Button("重新导入") {
                                    coordinator.reinstallApp(app)
                                }
                                .buttonStyle(.borderedProminent)
                                Button("删除此应用", role: .destructive) {
                                    showDeleteConfirm = true
                                }
                                .buttonStyle(.bordered)
                            } else {
                                if !packageExists {
                                    Button("重新安装") {
                                        coordinator.reinstallApp(app)
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                Button("删除此应用", role: .destructive) {
                                    showDeleteConfirm = true
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding()
                    }
                    .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
                    .confirmationDialog(
                        "删除“\(store.displayName(for: app))”？",
                        isPresented: $showDeleteConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("删除", role: .destructive) {
                            coordinator.deleteApp(app)
                            vm.openApp = nil
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("将删除应用本体、数据容器、钥匙串记录与桌面记录，原始 IPA 文件保留在 Documents/IPAs。")
                    }
                } else {
                    Text("未找到")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(app.map { store.displayName(for: $0) } ?? "详情")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Shared pieces

/// First-character icon tile. The color is a deterministic hash of the name
/// over a fixed palette (String.hashValue is salted per launch, so not used).
struct AppIconView: View {
    let name: String
    let size: CGFloat

    private static let palette: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal,
        .cyan, .blue, .indigo, .purple, .pink, .brown,
    ]

    private var tileColor: Color {
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        let index = (hash % Self.palette.count + Self.palette.count) % Self.palette.count
        return Self.palette[index]
    }

    var body: some View {
        Text(String(name.prefix(1)))
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tileColor, in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

/// 已装应用的图标：包内 SBIcon.png 存在就显示它（读磁盘文件），
/// 没有用默认色块 + 首字（沿用 AppIconView 的配色逻辑）。
struct InstalledAppIconView: View {
    let app: SBInstalledApp
    let size: CGFloat

    var body: some View {
        if let uiImage = UIImage(contentsOfFile: app.iconURL.path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            AppIconView(name: SBStore.shared.displayName(for: app), size: size)
        }
    }
}

/// The 获取 button, four states driven by SBStore + coordinator:
/// 未下载 → "获取"; 下载中 → download %; 安装中 → install %（真实进度）;
/// 已下载/已安装 → "已安装" (grey). 安装中再点获取会弹“正在安装，请稍候”。
private struct GetButtonView: View {
    let app: SourceApp
    var wide = false
    @ObservedObject var downloads: DownloadManager
    @EnvironmentObject private var coordinator: SBAppCoordinator
    // 只为订阅 SBStore：installedApps 变化（装完/删完）时本行要刷新；
    // “已安装”判断本身走 DownloadManager.isInstalled（读 SBStore）。
    @ObservedObject private var store = SBStore.shared

    var body: some View {
        if DownloadManager.isInstalled(app) {
            stateLabel("已安装", foreground: .secondary, background: Color(.secondarySystemFill))
        } else if coordinator.installingDisplayName == app.name {
            stateLabel(
                "\(Int(coordinator.installProgress.progress * 100))%",
                foreground: .white,
                background: .blue.opacity(0.75)
            )
        } else if downloads.downloading.contains(app.name) {
            stateLabel(
                "\(Int((downloads.progress[app.name] ?? 0) * 100))%",
                foreground: .white,
                background: .blue.opacity(0.75)
            )
        } else {
            Button { downloads.download(app, coordinator: coordinator) } label: {
                stateLabel("获取", foreground: .white, background: .accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    private func stateLabel(_ text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(minWidth: 64, maxWidth: wide ? .infinity : nil)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background, in: Capsule())
    }
}
