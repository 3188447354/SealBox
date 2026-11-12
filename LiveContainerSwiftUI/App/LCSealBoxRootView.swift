//
//  LCSealBoxRootView.swift
//  LiveContainerSwiftUI
//
//  SealBox app root (lane1): the desktop (LCAppListView) IS the root.
//  This replaces the old LCTabView four-tab root (deleted): there is no
//  Tab Bar anymore — Sources / Tweaks / Settings are desktop icons that
//  open from LCAppListView via fullScreenCover (demo §10). What this
//  view keeps from LCTabView is only the root-owned, non-Tab work:
//  the download alert, the last-launch crash report, the startup
//  checks (team id, bundle id, get-task-allow, container bookmark),
//  duplicate-window closing, and deep-link dispatch. Deep links no
//  longer switch a tab: they set SharedModel.requestedSystemPage
//  (.settings / .sources, or nil for "stay on the desktop") and then
//  SharedModel.deepLink, which the desktop / the system page consumes.
//

import Foundation
import SwiftUI

struct LCSealBoxRootView: View {
    @State var errorShow = false
    @State var crashReportShow = false
    @State var errorInfo = ""

    @EnvironmentObject var sharedModel : SharedModel
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State var shouldToggleMainWindowOpen = false
    @Environment(\.scenePhase) var scenePhase
    @StateObject var downloadHelper = DownloadHelper()

    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)

    var body: some View {
        LCAppListView()
            .downloadAlert(helper: downloadHelper)
            .environmentObject(downloadHelper)
            .alert("lc.common.error".loc, isPresented: $errorShow){
                Button("lc.common.ok".loc, action: {
                })
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
                            if #available(iOS 16.0, *) {
                                if let log = UserDefaults.lcShared().url(forKey: "LC32BitTranslationLayerLogFile") {
                                    ShareLink(item: log)
                                } else {
                                    ShareLink(item: errorInfo)
                                }
                            } else {
                                Button("lc.common.copy".loc) {
                                    copyError()
                                }
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("lc.common.ok".loc, action: {
                                crashReportShow = false
                            })
                        }
                    }
                    .navigationTitle("lc.common.error".loc)
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .task {
                closeDuplicatedWindow()
                checkLastLaunchError()
                checkTeamId()
                checkAndSaveBundleId()
                checkGetTaskAllow()
                checkPrivateContainerBookmark()
            }
            .onReceive(pub) { out in
                if let scene1 = sceneDelegate.window?.windowScene, let scene2 = out.object as? UIWindowScene, scene1 == scene2 {
                    if shouldToggleMainWindowOpen {
                        DataManager.shared.model.mainWindowOpened = false
                    }
                }
            }
            .onOpenURL { url in
                dispatchURL(url: url)
            }
    }

    /// Route a deep link: pick the system page it belongs to first
    /// (nil = the desktop itself), then hand the URL over. The order
    /// matters — LCAppListView opens the requested cover on the
    /// requestedSystemPage change, and the page then consumes deepLink.
    func dispatchURL(url: URL) {
        repeat {
            if url.isFileURL {
                sharedModel.requestedSystemPage = nil
                break
            }
            if url.scheme?.lowercased() == "sidestore" {
                sharedModel.requestedSystemPage = nil
                break
            }

            guard let host = url.host?.lowercased() else {
                return
            }

            switch host {
            case "sealbox-launch", "install", "open-web-page", "open-url":
                sharedModel.requestedSystemPage = nil
            case "certificate":
                sharedModel.requestedSystemPage = .settings
            case "source":
                sharedModel.requestedSystemPage = .sources
            default:
                return
            }

        } while(false)

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
            errorInfo = "Unable to determine application-identifier"
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

        if(bundleId != correctBundleId) {
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
            errorInfo = "Failed to create bookmark for Documents folder?"
            errorShow = true
            return
        }
        LCUtils.appGroupUserDefault.set(bookmark, forKey: "LCLaunchExtensionPrivateDocBookmark")
    }
}
