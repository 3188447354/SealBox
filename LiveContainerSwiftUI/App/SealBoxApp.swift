//
//  SealBoxApp.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — app entry point.
//
//  The `@main` struct is the `main` symbol LCBootstrap.m finds with
//  dlsym ("main") to bring the desktop back after a guest app exits:
//  it may be renamed, it must never lose `@main`. The app-loading code
//  below is the old LiveContainerSwiftUIApp init verbatim in behaviour
//  (scan Documents/Applications + the App Group shared bundles, build
//  LCAppModel per bundle, collect URL schemes and data/tweak folder
//  names); every model gets the shared launch coordinator as its
//  delegate so JIT-needed apps can ask for JIT instead of silently
//  doing nothing (a nil delegate used to swallow the JIT flow).
//
//  The old AppDelegate's Intents half (ViewAppIntent, LaunchAppExtension)
//  is gone with the deleted extension; the rest — JIT-modal cleanup on
//  terminate, the fullscreen scene-activation swizzle, the iOS-build
//  symbol-cache reset — is kept.

import SwiftUI

@main
struct SealBoxApp: SwiftUI.App {
    @UIApplicationDelegateAdaptor(SealBoxAppDelegate.self) var appDelegate

    init() {
        // 0.0.4: the whole UI is Chinese. Force the app language
        // before ANY localized string is read (NSLocalizedString
        // resolves against AppleLanguages at first use; on MJ's
        // phone the lookup was falling through to the en bundle and
        // the UI showed English). This only affects SealBox's own
        // strings — guest apps run in their own process/defaults.
        UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")

        let fm = FileManager()
        var tempAppDataFolderNames: [String] = []
        var tempTweakFolderNames: [String] = []

        var tempApps: [LCAppModel] = []
        var tempURLSchemes: Set<String>? = DataManager.shared.model.multiLCStatus != 2 ? Set() : nil

        do {
            // load apps
            try fm.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)
            let appDirs = try fm.contentsOfDirectory(atPath: LCPath.bundlePath.path)
            for appDir in appDirs {
                if !appDir.hasSuffix(".app") {
                    continue
                }
                guard let newApp = LCAppInfo(bundlePath: "\(LCPath.bundlePath.path)/\(appDir)") else {
                    continue
                }
                newApp.relativeBundlePath = appDir
                newApp.isShared = false
                let model = LCAppModel(appInfo: newApp, delegate: SealBoxLaunchCoordinator.shared)
                tempApps.append(model)
                tempURLSchemes?.formUnion(newApp.urlSchemes() as? [String] ?? [])
            }
            if LCPath.lcGroupDocPath != LCPath.docPath {
                try fm.createDirectory(at: LCPath.lcGroupBundlePath, withIntermediateDirectories: true)
                let appDirsShared = try fm.contentsOfDirectory(atPath: LCPath.lcGroupBundlePath.path)
                for appDir in appDirsShared {
                    if !appDir.hasSuffix(".app") {
                        continue
                    }
                    guard let newApp = LCAppInfo(bundlePath: "\(LCPath.lcGroupBundlePath.path)/\(appDir)") else {
                        continue
                    }
                    newApp.relativeBundlePath = appDir
                    newApp.isShared = true
                    let model = LCAppModel(appInfo: newApp, delegate: SealBoxLaunchCoordinator.shared)
                    tempApps.append(model)
                    tempURLSchemes?.formUnion(newApp.urlSchemes() as? [String] ?? [])
                }
            }
            // load document folders
            try fm.createDirectory(at: LCPath.dataPath, withIntermediateDirectories: true)
            let dataDirs = try fm.contentsOfDirectory(atPath: LCPath.dataPath.path)
            for dataDir in dataDirs {
                let dataDirUrl = LCPath.dataPath.appendingPathComponent(dataDir)
                if !dataDirUrl.hasDirectoryPath {
                    continue
                }
                tempAppDataFolderNames.append(dataDir)
            }

            // load tweak folders
            try fm.createDirectory(at: LCPath.tweakPath, withIntermediateDirectories: true)
            let tweakDirs = try fm.contentsOfDirectory(atPath: LCPath.tweakPath.path)
            for tweakDir in tweakDirs {
                let tweakDirUrl = LCPath.tweakPath.appendingPathComponent(tweakDir)
                if !tweakDirUrl.hasDirectoryPath {
                    continue
                }
                let folderName = tweakDir.hasSuffix(".disabled") ? String(tweakDir.dropLast(".disabled".count)) : tweakDir
                tempTweakFolderNames.append(folderName)
            }
        } catch {
            NSLog("[LC] error:\(error)")
        }

        DataManager.shared.model.apps = tempApps
        DataManager.shared.model.appDataFolderNames = tempAppDataFolderNames
        DataManager.shared.model.tweakFolderNames = tempTweakFolderNames
        if let tempURLSchemes {
            UserDefaults.lcShared().set(Array(tempURLSchemes), forKey: "LCGuestURLSchemes")
        }
    }

    var body: some Scene {
        // 0.0.8: single scene only. The multitask "appView" scene is
        // removed with the window mode — guest apps launch by
        // relaunching this process as the guest (classic launch), so
        // there is no second scene to host.
        WindowGroup(id: "Main") {
            RootView()
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .environmentObject(DataManager.shared.model)
        }
    }
}

@objc class SealBoxAppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.shortcutItems = nil
        UserDefaults.standard.removeObject(forKey: "LCNeedToAcquireJIT")

        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            // Fix launching app if user opens JIT waiting dialog and kills the app. Won't trigger normally.
            if DataManager.shared.model.isJITModalOpen && !UserDefaults.standard.bool(forKey: "LCKeepSelectedWhenQuit") {
                UserDefaults.standard.removeObject(forKey: "selected")
                UserDefaults.standard.removeObject(forKey: "selectedContainer")
            }
        }

        // remove symbol caches if user upgraded iOS
        if let lastIOSBuildVersion = LCUtils.appGroupUserDefault.string(forKey: "LCLastIOSBuildVersion"),
           let currentVersion = UIDevice.current.buildVersion,
           lastIOSBuildVersion == currentVersion {
        } else {
            LCUtils.appGroupUserDefault.removeObject(forKey: "symbolOffsetCache")
            LCUtils.appGroupUserDefault.setValue(UIDevice.current.buildVersion, forKey: "LCLastIOSBuildVersion")
        }

        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

class SceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        self.window = (scene as? UIWindowScene)?.keyWindow
    }
}
