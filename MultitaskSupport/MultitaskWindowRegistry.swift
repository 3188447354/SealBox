//
//  MultitaskWindowRegistry.swift
//  LiveContainer
//
//  Split out of MultitaskDockView.swift (lane1): the floating multitask
//  Dock UI is gone — MultitaskDockSwiftView, its collapse / hide /
//  edge-reveal / drag machinery, the hosting controller and all Dock
//  layout constants were deleted with that file, per the SealBox demo
//  (the desktop Dock is LCDesktopDockView.swift, a different component).
//
//  0.0.7: the floating virtual window is gone too. What stays here is
//  ONLY the running-window registry (MultitaskDockManager.apps) that
//  the app switcher reads: add/removeRunningApp, nothing more. The
//  virtual-window host view, bring-to-front view animation, PiP
//  handling, minimize-all and the isCollapsed flag all belonged to
//  the virtual window and are deleted with it. A native window is
//  brought to front by reopening its scene
//  (MultitaskWindowManager.openExistingAppWindow, via
//  LCAppModel.bringExistingMultitaskWindowIfNeeded); its live screen
//  is snapshotted from MultitaskWindowManager.sceneWindows
//  (GuestSceneSnapshot).
//
//  NOTE on naming: the class is still called MultitaskDockManager and
//  the model DockAppModel on purpose — renaming would touch every
//  engine call site for no behaviour gain. The "Dock" in the name is
//  historical; the Dock UI itself is gone.
//

import Foundation
import SwiftUI
import UIKit
import Combine

// MARK: - App Info Provider
class AppInfoProvider {

    static let shared = AppInfoProvider()

    private var infoCacheByUUID = [String: LCAppInfo]()
    private var infoCacheByName = [String: LCAppInfo]()
    private let cacheQueue = DispatchQueue(label: "com.mjorb.sealbox.appinfoprovider.cachequeue", attributes: .concurrent)

    private init() {}

    public func findAppInfo(appName: String, dataUUID: String) -> LCAppInfo? {
        if let appInfo = findAppInfoFromSharedModel(appName: appName, dataUUID: dataUUID) {
            return appInfo
        }
        if let appInfo = findAppInfo(byUUID: dataUUID) {
            return appInfo
        }
        return findAppInfo(byName: appName)
    }

    public func findAppInfo(byUUID dataUUID: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByUUID[dataUUID] }) {
            return cachedInfo
        }

        guard let appGroupPath = LCSharedUtils.appGroupPath()?.path else { return nil }

        let searchPaths = [
            "\(appGroupPath)/LiveContainer/Data/Application/\(dataUUID)/LCAppInfo.plist",
            "\(appGroupPath)/Containers/\(dataUUID)/LCAppInfo.plist",
            "\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "")/Data/Application/\(dataUUID)/LCAppInfo.plist"
        ]

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path),
               let appInfoDict = NSDictionary(contentsOfFile: path),
               let bundlePath = appInfoDict["bundlePath"] as? String,
               let appInfo = LCAppInfo(bundlePath: bundlePath) {

                cacheQueue.async(flags: .barrier) { self.infoCacheByUUID[dataUUID] = appInfo }
                return appInfo
            }
        }
        return nil
    }

    public func findAppInfo(byName appName: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByName[appName] }) {
            return cachedInfo
        }

        var searchPaths: [String] = []
        if let appGroupPath = LCSharedUtils.appGroupPath()?.path {
            searchPaths.append("\(appGroupPath)/LiveContainer/Applications")
        }
        if let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path {
            searchPaths.append("\(docPath)/Applications")
        }

        for appsPath in searchPaths {
            guard let appDirs = try? FileManager.default.contentsOfDirectory(atPath: appsPath) else { continue }

            for appDir in appDirs where appDir.hasSuffix(".app") {
                if let appInfo = LCAppInfo(bundlePath: "\(appsPath)/\(appDir)"), appInfo.displayName() == appName {
                    cacheQueue.async(flags: .barrier) { self.infoCacheByName[appName] = appInfo }
                    return appInfo
                }
            }
        }
        return nil
    }

    private func findAppInfoFromSharedModel(appName: String, dataUUID: String) -> LCAppInfo? {
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps

        for appModel in allApps {
            if appModel.appInfo.containers.contains(where: { $0.folderName == dataUUID }) {
                return appModel.appInfo
            }
        }

        for appModel in allApps {
            if appModel.appInfo.displayName() == appName {
                return appModel.appInfo
            }
        }
        return nil
    }

    public func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.infoCacheByUUID.removeAll()
            self.infoCacheByName.removeAll()
        }
    }
}

// MARK: - App Model for the running-window registry
@objc class DockAppModel: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    @objc let appName: String
    @objc let appUUID: String
    let appInfo: LCAppInfo?
    let view: UIView?

    @objc init(appName: String, appUUID: String, appInfo: LCAppInfo? = nil, view: UIView?) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = appInfo
        self.view = view
        super.init()
    }
}

// MARK: - Multitask window registry (engine; no Dock UI)
@available(iOS 16.0, *)
@objc public class MultitaskDockManager: NSObject, ObservableObject {
    @objc public static let shared = MultitaskDockManager()

    @Published var apps: [DockAppModel] = []

    @objc public func addRunningApp(_ appName: String, appUUID: String, view: UIView?) {
        let appInfo = AppInfoProvider.shared.findAppInfo(appName: appName, dataUUID: appUUID)
        addRunningAppWithInfo(appInfo, appUUID: appUUID, view: view)
    }

    @objc public func removeRunningApp(_ appUUID: String) {
        DispatchQueue.main.async {
            self.apps.removeAll { $0.appUUID == appUUID }
        }
    }

    @objc public func addRunningAppWithInfo(_ appInfo: LCAppInfo?, appUUID: String, view: UIView?) {
        if apps.contains(where: { $0.appUUID == appUUID }) {
            return
        }

        let appName = appInfo?.displayName() ?? "Unknown App"
        let appModel = DockAppModel(appName: appName, appUUID: appUUID, appInfo: appInfo, view: view)

        DispatchQueue.main.async {
            self.apps.append(appModel)
        }
    }

    // 0.0.7: the registry feeds the app switcher only. Native
    // entries carry view:nil; their scene window lives in
    // MultitaskWindowManager.sceneWindows (see GuestSceneSnapshot),
    // and an already-running app is brought to front by reopening
    // its scene (LCAppModel.bringExistingMultitaskWindowIfNeeded).
}
