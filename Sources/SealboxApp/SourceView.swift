import SwiftUI
import Foundation

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
/// queue, so every @Published update and every VMState call hops to the
/// main actor via Task { @MainActor }. The delegate-queue code itself only
/// touches the file system and the immutable catalog. The class is
/// @unchecked Sendable for that reason: its mutable state is only ever
/// read/written on the main actor (download() is called from UI actions).
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
    private weak var vm: VMState?

    /// Start downloading an app's IPA. No-op if it is already downloading
    /// or already installed.
    func download(_ app: SourceApp, vm: VMState) {
        guard !downloading.contains(app.name), !vm.isInstalled(app.name) else { return }
        self.vm = vm
        let task = session.downloadTask(with: app.url)
        task.taskDescription = app.name
        downloading.insert(app.name)
        progress[app.name] = 0
        task.resume()
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
              let app = SourceCatalog.all.first(where: { $0.name == name }) else { return }
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
                self.vm?.addInstalled(InstalledApp(
                    name: app.name,
                    version: app.version,
                    fileName: app.url.lastPathComponent,
                    category: app.category.rawValue
                ))
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.downloading.remove(name)
                self?.progress.removeValue(forKey: name)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil, let name = task.taskDescription else { return }
        Task { @MainActor [weak self] in
            self?.downloading.remove(name)
            self?.progress.removeValue(forKey: name)
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
    @EnvironmentObject private var vm: VMState
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
    @EnvironmentObject private var vm: VMState

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
                    if vm.isInstalled(app.name),
                       let size = VMFiles.ipaFileSizeString(fileName: app.url.lastPathComponent) {
                        Divider()
                            .padding(.vertical, 8)
                        infoRow(label: "文件大小", value: size)
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

/// Detail page for an app already downloaded from the source
/// (opened from the home screen via VMApp.installed).
struct InstalledAppDetailView: View {
    let name: String
    @EnvironmentObject private var vm: VMState
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if let app = vm.installed.first(where: { $0.name == name }) {
                    ScrollView {
                        VStack(spacing: 20) {
                            AppIconView(name: app.name, size: 96)
                                .padding(.top, 12)
                            VStack(spacing: 6) {
                                Text(app.name)
                                    .font(.title2.bold())
                                if let catalogApp = SourceCatalog.all.first(where: { $0.name == app.name }) {
                                    Text(catalogApp.intro)
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                infoRow(label: "版本号", value: app.version)
                                Divider()
                                    .padding(.vertical, 8)
                                infoRow(label: "文件名", value: app.fileName)
                                // Real disk size of the downloaded IPA file.
                                if let size = VMFiles.ipaFileSizeString(fileName: app.fileName) {
                                    Divider()
                                        .padding(.vertical, 8)
                                    infoRow(label: "文件大小", value: size)
                                }
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            Button("删除此应用", role: .destructive) {
                                showDeleteConfirm = true
                            }
                            .buttonStyle(.bordered)
                            Text("已下载到 Documents/IPAs，未安装到系统")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                    }
                    .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
                    .confirmationDialog(
                        "删除“\(app.name)”？",
                        isPresented: $showDeleteConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("删除", role: .destructive) {
                            vm.removeInstalled(app.name)
                            vm.openApp = nil
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("将删除已下载的 IPA 文件与记录。")
                    }
                } else {
                    Text("未找到")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
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

/// The 获取 button, three states driven by VMState (source of truth):
/// 未下载 → "获取"; 下载中 → progress %; 已下载/已安装 → "已安装" (grey).
private struct GetButtonView: View {
    let app: SourceApp
    var wide = false
    @ObservedObject var downloads: DownloadManager
    @EnvironmentObject private var vm: VMState

    var body: some View {
        if vm.isInstalled(app.name) {
            stateLabel("已安装", foreground: .secondary, background: Color(.secondarySystemFill))
        } else if downloads.downloading.contains(app.name) {
            stateLabel(
                "\(Int((downloads.progress[app.name] ?? 0) * 100))%",
                foreground: .white,
                background: .blue.opacity(0.75)
            )
        } else {
            Button { downloads.download(app, vm: vm) } label: {
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
