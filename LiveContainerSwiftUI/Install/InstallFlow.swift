//
//  InstallFlow.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — install flow + launch coordinator.
//
//  Three install entries converge here (research §3 step 1):
//  A. edit-mode "+" -> UIDocumentPicker (.ipa / .tipa only);
//  B. system share menu -> host opens with a file URL (RootView routes
//     it here); C. link / deep link -> installFromPlist / installFromUrl.
//  While one install is running, all three entries refuse with the
//  "正在安装，请稍候" error — installs are never queued.
//
//  Progress weights (research §3 step 4): decompress 80 / sign 20.
//  A download step (remote URL only) reports separately before that.
//
//  SealBoxLaunchCoordinator is the LCAppModelDelegate every LCAppModel
//  gets: with a nil delegate, runApp's JIT branch silently did nothing.
//  Multitask is frozen in v1, so showRunWhenMultitaskAlert refuses;
//  the JIT confirm dialog is a plain UIKit alert because the delegate
//  has no view to present from.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Replace / parallel-install choice

struct AppReplaceOption: Hashable {
    let isReplace: Bool
    let nameOfFolderToInstall: String
    let appToReplace: LCAppModel?

    func hash(into hasher: inout Hasher) {
        hasher.combine(isReplace)
        hasher.combine(nameOfFolderToInstall)
    }

    static func == (lhs: AppReplaceOption, rhs: AppReplaceOption) -> Bool {
        lhs.isReplace == rhs.isReplace && lhs.nameOfFolderToInstall == rhs.nameOfFolderToInstall
    }
}

/// A deep-link launch request queued by RootView for the desktop to consume.
struct PendingDeepLinkLaunch: Equatable {
    let bundleId: String
    let containerFolderName: String?
    let urlStr: String?
    let forceJIT: Bool?
}

// MARK: - Launch coordinator (LCAppModelDelegate)

final class SealBoxLaunchCoordinator: LCAppModelDelegate {
    static let shared = SealBoxLaunchCoordinator()

    private init() {}

    func closeNavigationView() {
        // v1 has no navigation stack to close.
    }

    func changeAppVisibility(app: LCAppModel) {
        // The grid filters on uiIsHidden directly; nothing else to do.
    }

    /// Multitask is frozen in v1: never run a shared app into a busy
    /// multitask session — refuse instead of asking. The refusal is
    /// intentional, but it must be visible (spec C6): runApp returns
    /// silently on false, so surface the reason through the desktop
    /// error alert instead of leaving the tap with no feedback.
    func showRunWhenMultitaskAlert() async -> Bool? {
        await MainActor.run {
            InstallFlow.shared.errorMessage = "已有应用在多任务中运行，请先退出它再打开共享应用。"
        }
        return false
    }

    func jitLaunch(appName: String, classicMode: UInt) async {
        await jitLaunch(withScript: "", appName: appName, classicMode: classicMode)
    }

    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {
        var log = ""
        // 0.0.7 audit fix (spec G3): askForJIT returns true only on
        // the TrollStore path, where it already launched the guest —
        // the old code ignored the return and launched it a second
        // time after the confirmation dialog.
        let jitRequested = await LCUtils.askForJIT(withScript: script, appName: appName, classicMode: classicMode) { newMsg in
            log += "\(newMsg)\n"
        }
        if jitRequested {
            return
        }
        // A missing "LCJITEnablerType" key reads as 0 (.SideJITServer)
        // via integer(forKey:) — never treat that phantom as a
        // configured enabler (same rule as SettingsView
        // jitEnablerText). With no enabler recorded, say so instead
        // of showing a bogus enable dialog and launching the guest
        // without JIT.
        guard let rawEnabler = LCUtils.appGroupUserDefault.object(forKey: "LCJITEnablerType") as? Int,
              JITEnablerType(rawValue: rawEnabler) != nil else {
            await MainActor.run {
                InstallFlow.shared.errorMessage = "未配置 JIT 开启器，请先在 Seal 里开启 JIT。"
            }
            UserDefaults.standard.removeObject(forKey: "selected")
            return
        }
        // askForJIT only *requests* JIT from the external enabler; the
        // user confirms in the enabler app, then we continue the launch.
        let goOn = await presentConfirmation(
            title: "lc.jit.enableTitle".loc,
            message: log.isEmpty ? "lc.jit.enableMessage".loc : log
        )
        guard goOn else {
            UserDefaults.standard.removeObject(forKey: "selected")
            return
        }
        LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)
    }

    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)

            // 0.0.7 audit fix (spec G3): same phantom-enabler rule as
            // jitLaunch(withScript:) — a missing key reads as 0
            // (.SideJITServer) via integer(forKey:). With no enabler
            // recorded, say so instead of opening a stikjit:// URL
            // no app can answer (silent no-op, guest runs without JIT).
            guard let rawEnabler = LCUtils.appGroupUserDefault.object(forKey: "LCJITEnablerType") as? Int,
                  let jitEnabler = JITEnablerType(rawValue: rawEnabler) else {
                InstallFlow.shared.errorMessage = "未配置 JIT 开启器，请先在 Seal 里开启 JIT。"
                return
            }
            if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                let encoded = encodedData.map { "&script=\($0)" } ?? ""
                // 0.0.7 audit fix: appName is a display name — a space
                // or non-ASCII in it makes URL(string:) return nil,
                // and the if-let below would silently skip opening
                // StosDebug (guest runs without JIT, no error shown).
                let encodedAppName = appName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? appName
                if jitEnabler == .StosDebugLC {
                    guard DataManager.shared.model.apps.contains(where: {
                        $0.appInfo.urlSchemes().contains("stosdebug") &&
                        (DataManager.shared.model.multiLCStatus != 2 || $0.appInfo.isShared)
                    }) else {
                        InstallFlow.shared.errorMessage = "找不到 StosDebug，请先安装并把它设为共享应用。"
                        return
                    }
                    if let url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(encodedAppName)&pid=\(pid)&relaunchApp=false&forcePID=true\(encoded)") {
                        UIApplication.shared.open(url)
                    }
                } else if let url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(encodedAppName)&pid=\(pid)&forcePID=true\(encoded)") {
                    UIApplication.shared.open(url)
                }
                return
            }

            let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
            if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                if jitEnabler == .StikJITLC {
                    guard DataManager.shared.model.apps.contains(where: {
                        $0.appInfo.urlSchemes().contains("stikjit") &&
                        (DataManager.shared.model.multiLCStatus != 2 || $0.appInfo.isShared)
                    }) else {
                        InstallFlow.shared.errorMessage = "找不到 StikDebug，请先安装并把它设为共享应用。"
                        return
                    }
                }
                UIApplication.shared.open(url)
            }
        }
    }

    /// A UIKit yes/no alert from whatever window is key. The delegate has
    /// no view, so SwiftUI alerts are not an option here.
    @MainActor
    private func presentConfirmation(title: String, message: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            guard let presenter = keyWindow?.rootViewController else {
                continuation.resume(returning: false)
                return
            }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "lc.common.cancel".loc, style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            alert.addAction(UIAlertAction(title: "lc.common.continue".loc, style: .default) { _ in
                continuation.resume(returning: true)
            })
            presenter.present(alert, animated: true)
        }
    }
}

// MARK: - Install flow

final class InstallFlow: ObservableObject {
    static let shared = InstallFlow()

    /// In-flight install state, for the progress pill.
    @Published private(set) var isInstalling = false
    /// 0...1 within the current phase (download, then install).
    @Published private(set) var progressFraction: Double = 0
    /// "正在下载" while fetching a remote IPA, "正在安装" afterwards.
    @Published private(set) var isDownloading = false
    /// Error text for the desktop's error alert (set on the main actor).
    @Published var errorMessage: String?

    /// Replace / parallel-install choice the desktop must ask about.
    /// Non-nil while the desktop's confirmation dialog is up.
    @Published private(set) var installOptions: [AppReplaceOption]?
    private var choiceContinuation: CheckedContinuation<AppReplaceOption?, Never>?

    /// Ids of apps installed by this session, in order — the desktop
    /// syncs its slot order and flips to the last page on each one.
    @Published private(set) var installedAppIDs: [String] = []

    /// Install / deep-link launch requests queued by RootView before the
    /// desktop exists; the desktop consumes them on appear / on change.
    @Published var pendingInstallURL: String?
    @Published var pendingLaunch: PendingDeepLinkLaunch?

    private var sharedModel: SharedModel { DataManager.shared.model }

    private init() {}

    // MARK: Entry points (called from the desktop / RootView)

    func requestInstall(urlString: String) {
        pendingInstallURL = urlString
    }

    func consumePendingInstall() -> String? {
        let url = pendingInstallURL
        pendingInstallURL = nil
        return url
    }

    func requestDeepLinkLaunch(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var bundleId: String?
        var containerName: String?
        var forceJIT: Bool?
        var urlStr: String?
        for queryItem in components.queryItems ?? [] {
            switch queryItem.name {
            case "bundle-name":
                bundleId = queryItem.value
            case "container-folder-name":
                containerName = queryItem.value
            case "jit":
                if queryItem.value == "true" { forceJIT = true }
                else if queryItem.value == "false" { forceJIT = false }
            case "open-url":
                if let value = queryItem.value,
                   let decodedData = Data(base64Encoded: value),
                   let decodedUrl = String(data: decodedData, encoding: .utf8) {
                    urlStr = decodedUrl
                }
            default:
                break
            }
        }
        if let bundleId, !bundleId.isEmpty, bundleId != "ui" {
            pendingLaunch = PendingDeepLinkLaunch(
                bundleId: bundleId,
                containerFolderName: containerName,
                urlStr: urlStr,
                forceJIT: forceJIT
            )
        }
    }

    func consumePendingLaunch() -> PendingDeepLinkLaunch? {
        let launch = pendingLaunch
        pendingLaunch = nil
        return launch
    }

    // MARK: Replace choice (desktop confirmation dialog)

    func chooseReplaceOption(_ option: AppReplaceOption?) {
        installOptions = nil
        choiceContinuation?.resume(returning: option)
        choiceContinuation = nil
    }

    private func askReplaceOption(_ options: [AppReplaceOption]) async -> AppReplaceOption? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.choiceContinuation = continuation
                self.installOptions = options
            }
        }
    }

    // MARK: URL / plist installs

    func startInstallFromUrlString(_ urlString: String) async {
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "itms-services" else {
            await installFromUrl(urlStr: urlString)
            return
        }
        await installFromPlist(urlStr: urlString)
    }

    func installFromPlist(urlStr: String) async {
        if isInstalling {
            await reportInstallBusy()
            return
        }
        if sharedModel.multiLCStatus == 2 {
            await reportError("lc.appList.manageInPrimaryTip".loc)
            return
        }

        var plistUrlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                await reportError("lc.appList.plistInvalidError".loc)
                return
            }
        }

        guard let plistUrl = URL(string: plistUrlStr) else {
            await reportError("lc.appList.urlInvalidError".loc)
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: plistUrl)
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                await reportError("lc.appList.plistParseError".loc)
                return
            }
            var ipaUrlStr: String?
            for asset in assets {
                if let kind = asset["kind"] as? String, kind == "software-package",
                   let url = asset["url"] as? String {
                    ipaUrlStr = url
                    break
                }
            }
            guard let ipaUrlStr else {
                await reportError("lc.appList.plistNoIpaError".loc)
                return
            }
            await installFromUrl(urlStr: ipaUrlStr)
        } catch {
            await reportError(error.localizedDescription)
        }
    }

    func installFromUrl(urlStr: String) async {
        // Ignore any install request while another install is running.
        if isInstalling {
            await reportInstallBusy()
            return
        }
        if sharedModel.multiLCStatus == 2 {
            await reportError("lc.appList.manageInPrimaryTip".loc)
            return
        }

        guard var installUrl = URL(string: urlStr) else {
            await reportError("lc.appList.urlInvalidError".loc)
            return
        }

        await setInstalling(true)
        defer { Task { await self.setInstalling(false) } }

        if installUrl.isFileURL {
            let fileExtension = installUrl.pathExtension.lowercased()
            if fileExtension != "ipa" && fileExtension != "tipa" {
                await reportError("lc.appList.urlFileIsNotIpaError".loc)
                return
            }

            let fm = FileManager.default
            var didStartAccessing = false
            if !fm.isReadableFile(atPath: installUrl.path),
               let bookmarkData = LCUtils.appGroupUserDefault.data(forKey: "LCLaunchExtensionFileBookmark") {
                do {
                    var isStale = false
                    let resolvedURL = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: URL.BookmarkResolutionOptions(rawValue: 1 << 10),
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    installUrl = resolvedURL
                    didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                } catch {
                    await reportError("解析共享 IPA 书签失败：\(error.localizedDescription)")
                    return
                }
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                didStartAccessing = installUrl.startAccessingSecurityScopedResource()
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                await reportError("lc.appList.ipaAccessError".loc)
                return
            }

            defer {
                if didStartAccessing {
                    installUrl.stopAccessingSecurityScopedResource()
                }
            }

            // Share-extension handoff: the staged file lives in the App
            // Group inbox (<appGroup>/LiveContainer/ShareInbox — the
            // extension's ShareExtensionViewModel.inboxDirectory). The
            // host can read it without a bookmark because it is in the
            // shared container. Delete it after a successful install so
            // it never becomes litter, and clear the marker keys the
            // extension wrote. A failed install leaves the file in
            // place (it can be re-shared). Note installIpaFile reports
            // signing problems itself without throwing; only a throw
            // means "not installed".
            var installSucceeded = false
            do {
                try await installIpaFile(installUrl)
                installSucceeded = true
            } catch {
                await reportError(error.localizedDescription)
            }
            if installSucceeded, Self.isShareInboxFile(installUrl) {
                try? fm.removeItem(at: installUrl)
                LCUtils.appGroupUserDefault.removeObject(forKey: "LCShareInboxFileName")
                LCUtils.appGroupUserDefault.removeObject(forKey: "LCShareInboxOriginalName")
                LCUtils.appGroupUserDefault.removeObject(forKey: "LCShareInboxDate")
            }

            do {
                // Delete the IPA if it came from the Inbox (share sheet).
                var shouldDelete = false
                if let documentsDirectory = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let inboxURL = documentsDirectory.appendingPathComponent("Inbox")
                    shouldDelete = installUrl.deletingLastPathComponent().standardizedFileURL == inboxURL.standardizedFileURL
                }
                if shouldDelete {
                    try fm.removeItem(at: installUrl)
                }
            } catch {
                await reportError(error.localizedDescription)
            }
            return
        }

        do {
            let fileManager = FileManager.default
            let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(installUrl.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try await download(url: installUrl, to: destinationURL)
            try await installIpaFile(destinationURL)
            try fileManager.removeItem(at: destinationURL)
        } catch {
            await reportError(error.localizedDescription)
        }
    }

    // MARK: Core install (port of the old installIpaFile)

    /// Decompresses, parses, patches + signs, and registers the IPA.
    /// Signing failure does NOT roll the install back: the app is left
    /// installed unsigned and the detail page marks it "未签名 / JIT 启动".
    func installIpaFile(_ url: URL) async throws {
        let fm = FileManager()

        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        installProgress.addChild(decompressProgress, withPendingUnitCount: 80)
        await setProgress(0, downloading: false)
        let installObserver = installProgress.observe(\.fractionCompleted) { progress, _ in
            Task { @MainActor in
                InstallFlow.shared.progressFraction = progress.fractionCompleted
            }
        }

        let payloadPath = fm.temporaryDirectory.appendingPathComponent("Payload")
        if fm.fileExists(atPath: payloadPath.path) {
            try fm.removeItem(at: payloadPath)
        }

        // Decompress (blocking C call — off the main actor).
        let extractResult = await Task.detached {
            extract(url.path, fm.temporaryDirectory.path, decompressProgress)
        }.value
        guard extractResult == 0 else {
            throw "lc.appList.urlFileIsNotIpaError".loc
        }

        let payloadContents = try fm.contentsOfDirectory(atPath: payloadPath.path)
        var appBundleName: String?
        for fileName in payloadContents {
            if fileName.hasSuffix(".app") {
                appBundleName = fileName
                break
            }
        }
        guard let appBundleName else {
            throw "lc.appList.bundleNotFondError".loc
        }

        let appFolderPath = payloadPath.appendingPathComponent(appBundleName)
        guard let newAppInfo = LCAppInfo(bundlePath: appFolderPath.path) else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }
        guard let newBundleId = newAppInfo.bundleIdentifier() else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }

        var appRelativePath = "\(newBundleId.sanitizeNonACSII()).app"
        var outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
        var appToReplace: LCAppModel?
        // Same Bundle ID already installed: replace or parallel-install.
        let sameBundleIdApp = sharedModel.apps.filter { app in
            app.appInfo.bundleIdentifier() == newBundleId
        }

        if fm.fileExists(atPath: outputFolder.path) || !sameBundleIdApp.isEmpty {
            appRelativePath = "\(newBundleId)_\(Int(CFAbsoluteTimeGetCurrent())).app"

            var options = [AppReplaceOption(isReplace: false, nameOfFolderToInstall: appRelativePath, appToReplace: nil)]
            for app in sameBundleIdApp {
                options.append(AppReplaceOption(isReplace: true, nameOfFolderToInstall: app.appInfo.relativeBundlePath, appToReplace: app))
            }

            guard let installOptionChosen = await askReplaceOption(options) else {
                // User cancelled: clear the temp Payload, leave nothing.
                try fm.removeItem(at: payloadPath)
                return
            }

            if let appToReplace = installOptionChosen.appToReplace, appToReplace.uiIsShared {
                outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            } else {
                outputFolder = LCPath.bundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            }
            appRelativePath = installOptionChosen.nameOfFolderToInstall
            appToReplace = installOptionChosen.appToReplace
            if installOptionChosen.isReplace {
                try fm.removeItem(at: outputFolder)
            }
        }
        // Move it!
        try fm.moveItem(at: appFolderPath, to: outputFolder)
        guard let finalNewApp = LCAppInfo(bundlePath: outputFolder.path) else {
            await reportError("lc.appList.appInfoInitError".loc)
            return
        }
        finalNewApp.relativeBundlePath = appRelativePath

        // Patch and sign it (sign = 20 of the 100 progress units).
        var signError: String?
        var signSuccess = false
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            if appToReplace?.uiDontSign ?? false || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
                finalNewApp.dontSign = true
            }
            finalNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error
                signSuccess = success
                continuation.resume()
            }, progressHandler: { signProgress in
                if let signProgress {
                    installProgress.addChild(signProgress, withPendingUnitCount: 20)
                }
            }, forceSign: false)
        }

        // We leave it unsigned even if signing failed.
        if let signError {
            if signSuccess {
                await reportError("\("lc.appList.signSuccessWithError".loc)\n\n\(signError)")
            } else {
                await reportError(signError.loc)
            }
        }

        if let appToReplace {
            // Copy the previous configuration to the new app.
            finalNewApp.autoSaveDisabled = true
            finalNewApp.isLocked = appToReplace.appInfo.isLocked
            finalNewApp.isHidden = appToReplace.appInfo.isHidden
            finalNewApp.isJITNeeded = appToReplace.appInfo.isJITNeeded
            finalNewApp.isShared = appToReplace.appInfo.isShared
            finalNewApp.spoofSDKVersion = appToReplace.appInfo.spoofSDKVersion
            finalNewApp.doSymlinkInbox = appToReplace.appInfo.doSymlinkInbox
            finalNewApp.containerInfo = appToReplace.appInfo.containerInfo
            finalNewApp.tweakFolder = appToReplace.appInfo.tweakFolder
            finalNewApp.selectedLanguage = appToReplace.appInfo.selectedLanguage
            finalNewApp.dataUUID = appToReplace.appInfo.dataUUID
            finalNewApp.orientationLock = appToReplace.appInfo.orientationLock
            finalNewApp.dontInjectTweakLoader = appToReplace.appInfo.dontInjectTweakLoader
            finalNewApp.hideLiveContainer = appToReplace.appInfo.hideLiveContainer
            finalNewApp.dontLoadTweakLoader = appToReplace.appInfo.dontLoadTweakLoader
            finalNewApp.doUseLCBundleId = appToReplace.appInfo.doUseLCBundleId
            finalNewApp.fixFilePickerNew = appToReplace.appInfo.fixFilePickerNew
            finalNewApp.fixLocalNotification = appToReplace.appInfo.fixLocalNotification
            finalNewApp.lastLaunched = appToReplace.appInfo.lastLaunched
            finalNewApp.jitLaunchScriptJs = appToReplace.appInfo.jitLaunchScriptJs
            finalNewApp.multitaskSpecified = appToReplace.appInfo.multitaskSpecified
            finalNewApp.classicMode = appToReplace.appInfo.classicMode
            finalNewApp.autoSaveDisabled = false
            finalNewApp.save()
        } else {
            // Enable SDK version spoof by default.
            finalNewApp.spoofSDKVersion = true
        }
        finalNewApp.installationDate = Date.now

        installObserver.invalidate()
        // Snapshot the two vars before the concurrent closure: both were
        // last written far above (lines ~524-525) and only read below, but
        // capturing a var in MainActor.run's @Sendable body is a Swift 6
        // data-race diagnostic (CI warned on both).
        let replacement = appToReplace
        let relativePath = appRelativePath
        await MainActor.run {
            if let appToReplace = replacement {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: SealBoxLaunchCoordinator.shared)
                sharedModel.apps.removeAll { $0 == appToReplace }
                sharedModel.apps.append(newAppModel)
            } else {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: SealBoxLaunchCoordinator.shared)
                sharedModel.apps.append(newAppModel)

                // Register URL schemes.
                if let urlSchemes = finalNewApp.urlSchemes(), urlSchemes.count > 0 {
                    UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                        .addObjects(from: urlSchemes as! [Any])
                }
            }
            installedAppIDs.append("\(newBundleId):\(relativePath)")
        }
    }

    // MARK: Download (replaces the deleted DownloadHelper)

    private func download(url: URL, to destinationURL: URL) async throws {
        await setProgress(0, downloading: true)
        let (tempURL, _) = try await URLSession.shared.download(from: url)
        // Report download as complete; install progress takes over next.
        await setProgress(1, downloading: true)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        await setProgress(0, downloading: false)
    }

    // MARK: Share-extension inbox

    /// Whether a file URL points inside the share-extension inbox
    /// (<appGroup>/LiveContainer/ShareInbox). Same directory the
    /// extension stages into (ShareExtensionViewModel.inboxDirectory);
    /// derived here from LCPath.lcGroupDocPath.
    static func isShareInboxFile(_ url: URL) -> Bool {
        let inbox = LCPath.lcGroupDocPath.appendingPathComponent("ShareInbox").path
        return url.path.hasPrefix(inbox + "/")
    }

    // MARK: State helpers

    @MainActor
    private func setInstalling(_ value: Bool) {
        isInstalling = value
        if value {
            progressFraction = 0
        }
    }

    @MainActor
    private func setProgress(_ value: Double, downloading: Bool) {
        progressFraction = value
        isDownloading = downloading
    }

    @MainActor
    private func reportError(_ message: String) {
        errorMessage = message
    }

    @MainActor
    private func reportInstallBusy() {
        errorMessage = "lc.appList.installingPleaseWait".loc
    }
}

// MARK: - IPA document picker (install entry A)

struct IPADocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.ipa, .tipa], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPick(url)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // Silent return to the desktop, no prompt.
        }
    }
}
