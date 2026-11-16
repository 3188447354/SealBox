//
//  RootView.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — app root.
//
//  The desktop IS the root: no Tab Bar, no title, no toolbar. The root
//  owns only the non-desktop work the old LCSealBoxRootView owned:
//  the last-launch crash report, the startup checks (team id, bundle id,
//  get-task-allow, container bookmark), duplicate-window closing, and
//  deep-link dispatch — plus the certificate gate: with no imported
//  certificate the user sees the import guide instead of the desktop,
//  because on iOS 26+ a guest app cannot even reach the launch entry
//  without one (LCBootstrap.m hard gate; research §2.3). The gate is
//  dismissible back to the desktop once a certificate exists; it never
//  blocks the desktop itself, only guest launches (see CertificateGate).

import Foundation
import SwiftUI

struct RootView: View {
    @State var errorShow = false
    @State var crashReportShow = false
    @State var errorInfo = ""

    @EnvironmentObject var sharedModel: SharedModel
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State var shouldToggleMainWindowOpen = false
    @Environment(\.scenePhase) var scenePhase
    @State private var certificateImported = hasImportedCertificate

    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)

    var body: some View {
        Group {
            if certificateImported {
                DesktopView()
            } else {
                CertificateGateView(onCertificateImported: {
                    certificateImported = true
                })
            }
        }
        .alert("lc.common.error", isPresented: $errorShow) {
            Button("lc.common.ok".loc, action: {})
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .sheet(isPresented: $crashReportShow) {
            NavigationView {
                ScrollView {
                    Text(errorInfo)
                        .font(.system(size: 12).monospaced())
                        .fixedSize(horizontal: false, vertical: false)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("lc.common.copy".loc) {
                            copyError()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("lc.common.ok".loc, action: {
                            crashReportShow = false
                        })
                    }
                }
                .navigationTitle("lc.common.error")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        // Settings (implementation #2) is mounted here, at the root —
        // not in the desktop — because the certificate gate asks for it
        // BEFORE the desktop exists: with no certificate RootView shows
        // the gate instead of the desktop, and the gate's "Go to
        // Settings" sets requestedSystemPage = .settings. Mounting the
        // cover here closes that half-open flow: gate → settings →
        // real p12 import → notification → desktop.
        .fullScreenCover(isPresented: settingsCoverBinding) {
            SettingsView(
                onDone: {
                    sharedModel.requestedSystemPage = nil
                },
                onOpenSwitcher: {
                    sharedModel.requestedSystemPage = nil
                    NotificationCenter.default.post(name: Notification.Name("SealBoxOpenAppSwitcher"), object: nil)
                }
            )
        }
        .task {
            closeDuplicatedWindow()
            checkLastLaunchError()
            checkTeamId()
            checkAndSaveBundleId()
            checkGetTaskAllow()
            checkPrivateContainerBookmark()
            // The certificate may have been imported while the app was
            // in the background (e.g. via Seal); re-check on launch.
            certificateImported = hasImportedCertificate
        }
        .onReceive(pub) { out in
            if let scene1 = sceneDelegate.window?.windowScene, let scene2 = out.object as? UIWindowScene, scene1 == scene2 {
                if shouldToggleMainWindowOpen {
                    DataManager.shared.model.mainWindowOpened = false
                }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                certificateImported = hasImportedCertificate
            }
        }
        .onOpenURL { url in
            dispatchURL(url: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SealBoxCertificateImported"))) { _ in
            certificateImported = hasImportedCertificate
        }
    }

    /// Route a deep link: pick the system page it belongs to first
    /// (nil = the desktop itself), then hand the URL over. Install and
    /// launch requests are queued on InstallFlow for the desktop to
    /// consume; the desktop owns the install / launch UI.
    ///
    /// The settings cover is bound to requestedSystemPage == .settings
    /// (see the fullScreenCover above): a "certificate" deep link opens
    /// SettingsView, which consumes the link and opens the p12 import.
    private var settingsCoverBinding: Binding<Bool> {
        Binding(
            get: { sharedModel.requestedSystemPage == .settings },
            set: { if !$0 { sharedModel.requestedSystemPage = nil } }
        )
    }

    func dispatchURL(url: URL) {
        if url.isFileURL {
            sharedModel.requestedSystemPage = nil
            InstallFlow.shared.requestInstall(urlString: url.absoluteString)
            return
        }

        guard let host = url.host?.lowercased() else {
            return
        }

        switch host {
        case "sealbox-launch":
            sharedModel.requestedSystemPage = nil
            InstallFlow.shared.requestDeepLinkLaunch(url: url)
        case "install":
            sharedModel.requestedSystemPage = nil
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let installUrl = components.queryItems?.first(where: { $0.name == "url" })?.value {
                InstallFlow.shared.requestInstall(urlString: installUrl)
            }
        case "certificate":
            sharedModel.requestedSystemPage = .settings
            sharedModel.deepLink = url
        default:
            return
        }
        sharedModel.deepLink = url
    }

    func closeDuplicatedWindow() {
        if let session = sceneDelegate.window?.windowScene?.session, DataManager.shared.model.mainWindowOpened {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { e in
                print(e)
            }
        } else {
            shouldToggleMainWindowOpen = true
        }
        DataManager.shared.model.mainWindowOpened = true
    }

    func checkLastLaunchError() {
        var errorStr = UserDefaults.standard.string(forKey: "error")

        if errorStr == nil && UserDefaults.standard.bool(forKey: "SigningInProgress") {
            errorStr = "lc.signer.crashDuringSignErr".loc
            UserDefaults.standard.removeObject(forKey: "SigningInProgress")
        }

        guard let errorStr else {
            return
        }
        UserDefaults.standard.removeObject(forKey: "error")
        errorInfo = errorStr
        crashReportShow = true
    }

    func copyError() {
        UIPasteboard.general.string = errorInfo
    }

    func checkTeamId() {
        if let certificateTeamId = UserDefaults.standard.string(forKey: "LCCertificateTeamId") {
            if DataManager.shared.model.multiLCStatus != 2 {
                return
            }

            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if certificateTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
            return
        }

        guard let currentTeamId = LCSharedUtils.teamIdentifier() else {
            print("Failed to determine team id.")
            return
        }

        if DataManager.shared.model.multiLCStatus == 2 {
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if currentTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
        }
        UserDefaults.standard.set(currentTeamId, forKey: "LCCertificateTeamId")
    }

    func checkAndSaveBundleId() {
        if DataManager.shared.model.multiLCStatus == 2 {
            let scheme = UserDefaults.lcAppUrlScheme() ?? ""
            LCUtils.appGroupUserDefault.set(Bundle.main.bundleIdentifier, forKey: "LCBundleID.\(scheme)")
        }

        if UserDefaults.standard.bool(forKey: "LCBundleIdChecked") {
            return
        }

        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "application-identifier" as CFString, nil), let appIdentifier = value.takeRetainedValue() as? String else {
            errorInfo = "无法确定应用标识（application-identifier）"
            errorShow = true
            return
        }

        guard let bundleId = Bundle.main.bundleIdentifier else {
            return
        }

        var correctBundleId = ""
        if appIdentifier.count > 11 {
            let startIndex = appIdentifier.index(appIdentifier.startIndex, offsetBy: 11)
            correctBundleId = String(appIdentifier[startIndex...])
        }

        if bundleId != correctBundleId {
            errorInfo = "lc.settings.bundleIdMismatch %@ %@".localizeWithFormat(bundleId, correctBundleId)
            errorShow = true
        }
        UserDefaults.standard.set(true, forKey: "LCBundleIdChecked")
    }

    func checkGetTaskAllow() {
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "get-task-allow" as CFString, nil), (value.takeRetainedValue() as? NSNumber)?.boolValue ?? false else {
            errorInfo = "lc.settings.notDevCert".loc
            errorShow = true
            return
        }
    }

    func checkPrivateContainerBookmark() {
        if sharedModel.multiLCStatus == 2 {
            return
        }
        if LCUtils.appGroupUserDefault.object(forKey: "LCLaunchExtensionPrivateDocBookmark") != nil {
            return
        }

        guard let bookmark = LCUtils.bookmark(for: LCPath.docPath) else {
            errorInfo = "无法为 Documents 文件夹创建书签？"
            errorShow = true
            return
        }
        LCUtils.appGroupUserDefault.set(bookmark, forKey: "LCLaunchExtensionPrivateDocBookmark")
    }
}
