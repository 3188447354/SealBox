//
//  ShareExtensionViewModel.swift
//  ShareExtension
//
//  SealBox 0.0.3 rebuild — share-to-install only (implementation #2).
//
//  Flow (research §3 step 1, entry B):
//  1. Load the shared item. A local .ipa / .tipa file is staged into
//     the App Group shared directory
//     (<appGroup>/LiveContainer/ShareInbox/<uuid>-<name>.ipa); a remote
//     direct .ipa link needs no staging.
//  2. The user taps "安装到 SealBox".
//  3. The extension opens the host with sealbox://install?url=<...>
//     via LCShareExtensionLauncher (the LSApplicationWorkspace chain
//     the old flow already used) and completes the request. The host's
//     RootView routes host "install" to InstallFlow, which installs
//     the file — step 3 of the install flow, skipping file picking.
//  4. The host deletes the staged file after a successful install and
//     clears the marker keys (see InstallFlow).
//
//  Why a URL scheme, not just a UserDefaults marker: the extension
//  cannot wake the host — only opening a URL can. The App Group
//  directory is the transport (the extension's own container is not
//  readable by the host); the marker keys
//  (LCShareInboxFileName / LCShareInboxOriginalName / LCShareInboxDate)
//  are only a record of what was staged, so a staged file is never
//  anonymous litter. The scheme URL is the trigger; the directory is
//  where the file lives.
//
//  What is NOT here any more: the guest-app list, container picker,
//  per-app launch, hidden-app unlock, built-in SideStore launch, and
//  the LCLaunchExtensionFileBookmark handoff (the staged file lives in
//  the App Group, so the host can read it without a bookmark).

import Combine
import Foundation

@MainActor
final class ShareExtensionViewModel: ObservableObject {
    @Published var payload = SharePayload()
    @Published var staged: StagedIPA?
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var didOpenHost = false

    weak var currentContext: NSExtensionContext?
    private var hasLoaded = false

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: LCSharedUtils.appGroupID())
    }

    /// The App Group staging directory both targets agree on:
    /// <appGroup>/LiveContainer/ShareInbox. The host derives the same
    /// path from LCPath.lcGroupDocPath.
    static var inboxDirectory: URL? {
        LCSharedUtils.appGroupPath()?
            .appendingPathComponent("LiveContainer")
            .appendingPathComponent("ShareInbox")
    }

    // MARK: - Load + stage

    func loadPayload(from context: NSExtensionContext?) {
        if let context {
            currentContext = context
        }
        // beginRequest and viewDidLoad both call this; load once.
        guard !hasLoaded else { return }
        hasLoaded = true
        Task {
            do {
                let loaded = try await SharePayload.load(from: context)
                await MainActor.run {
                    self.payload.kind = loaded
                }
                if case .file(let fileURL) = loaded {
                    await stageSharedFile(fileURL)
                }
            } catch {
                await MainActor.run {
                    self.payload.kind = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Copy the shared .ipa into the App Group inbox (background copy;
    /// IPAs can be hundreds of MB) and record the marker keys.
    private func stageSharedFile(_ fileURL: URL) async {
        isWorking = true
        defer { isWorking = false }
        do {
            // Resolve on the main actor first: inboxDirectory is
            // MainActor-isolated (class is @MainActor), so the detached
            // copy below must not touch it — it only captures this URL.
            guard let inbox = Self.inboxDirectory else {
                throw ShareExtensionError("无法找到共享目录。")
            }
            let stagedResult = try await Task.detached {
                let accessing = fileURL.startAccessingSecurityScopedResource()
                defer {
                    if accessing { fileURL.stopAccessingSecurityScopedResource() }
                }
                let fm = FileManager.default
                try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
                let originalName = fileURL.lastPathComponent
                let safeName = originalName
                    .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")))
                    .filter { !$0.isEmpty }
                    .joined()
                let fileName = "\(UUID().uuidString)-\(safeName.isEmpty ? "app.ipa" : safeName)"
                let destination = inbox.appendingPathComponent(fileName)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: fileURL, to: destination)
                let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
                return StagedIPA(stagedURL: destination, originalName: originalName, size: size)
            }.value
            self.staged = stagedResult
            sharedDefaults?.set(stagedResult.stagedURL.lastPathComponent, forKey: ShareInboxKeys.fileName)
            sharedDefaults?.set(stagedResult.originalName, forKey: ShareInboxKeys.originalName)
            sharedDefaults?.set(Date(), forKey: ShareInboxKeys.date)
        } catch {
            errorMessage = error.localizedDescription
            payload.kind = .failed(error.localizedDescription)
        }
    }

    // MARK: - Hand off to the host

    /// Install the staged file (or the remote direct link) in the host.
    func install(context: NSExtensionContext?) async {
        if isWorking {
            return
        }
        isWorking = true
        defer { isWorking = false }

        let installURLString: String?
        switch payload.kind {
        case .file:
            guard let staged else {
                errorMessage = "文件还在准备中，请稍候再试。"
                return
            }
            installURLString = staged.stagedURL.absoluteString
        case .remoteIPA(let url):
            installURLString = url.absoluteString
        case .failed(let message):
            errorMessage = message
            return
        default:
            errorMessage = "没有可安装的文件。"
            return
        }

        guard let installURLString,
              var components = URLComponents(string: "sealbox://install") else {
            errorMessage = "无法构建安装链接。"
            return
        }
        components.queryItems = [URLQueryItem(name: "url", value: installURLString)]
        guard let installURL = components.url else {
            errorMessage = "无法构建安装链接。"
            return
        }

        // Opens the host (LSApplicationWorkspace chain in main.m);
        // RootView routes host "install" to InstallFlow. (The launcher
        // reports true unconditionally in main.m; the result is not a
        // reliable open confirmation.)
        _ = LCShareExtensionLauncher.openURL(fromShareExtension: installURL)
        didOpenHost = true
        (context ?? currentContext)?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    func cancelRequest() {
        (currentContext)?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
