//
//  MultitaskAppWindow.swift
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
import SwiftUI

@available(iOS 16.1, *)
struct MultitaskAppInfo {
    var displayName: String
    var dataUUID: String
    var bundleId: String
    
    init(displayName: String, dataUUID: String, bundleId: String) {
        self.displayName = displayName
        self.dataUUID = dataUUID
        self.bundleId = bundleId
    }
}

/// Weak holder so a window registry never keeps a dead window alive.
final class WeakWindowBox {
    weak var window: UIWindow?
    init(_ window: UIWindow?) { self.window = window }
}

@available(iOS 16.1, *)
// 0.0.6: the real openWindow action is captured from the Main
// scene's environment (RootView -> OpenWindowRegistrar) and stored
// here. A static @Environment on this class used to read only the
// default no-op action outside any View body, so openWindow did
// nothing: the scene never opened, the pid callback never fired and
// runApp hung forever while the launch zoom stayed frozen (0.0.5).
// Set once by the Main scene on appear, before any launch.
@objc class MultitaskWindowManager: NSObject {
    static var openWindowAction: OpenWindowAction?
    static var appDict: [String: MultitaskAppInfo] = [:]

    /// The live window of each native app scene, keyed by dataUUID.
    /// The switcher snapshots these for its cards (GuestSceneSnapshot).
    /// Registered by MultitaskAppWindow on appear, removed on
    /// disappear / scene disconnect.
    static var sceneWindows: [String: WeakWindowBox] = [:]

    @objc class func registerSceneWindow(dataUUID: String, window: UIWindow?) {
        guard let window else { return }
        sceneWindows[dataUUID] = WeakWindowBox(window)
    }

    @objc class func unregisterSceneWindow(dataUUID: String) {
        sceneWindows.removeValue(forKey: dataUUID)
    }

    /// Drop every trace of a native app window: the open-scene table
    /// (so a later tap relaunches instead of reopening a dead scene),
    /// the scene-window registry, and the switcher registry. Called
    /// when the guest exits (AppSceneViewController delegate) and
    /// when the scene disconnects.
    @objc class func removeAppWindow(dataUUID: String) {
        appDict.removeValue(forKey: dataUUID)
        sceneWindows.removeValue(forKey: dataUUID)
        MultitaskDockManager.shared.removeRunningApp(dataUUID)
    }
    
    @objc class func openAppWindow(displayName: String, dataUUID: String, bundleId: String, pidCallback: ((NSNumber, Error?) -> Void)?) {
        DataManager.shared.model.enableMultipleWindow = true
        DataManager.shared.model.pidCallback = pidCallback
        appDict[dataUUID] = MultitaskAppInfo(displayName: displayName, dataUUID: dataUUID, bundleId: bundleId)
        // A scene open needs a real environment action; if it is
        // missing (Main scene not up yet), fail the callback instead
        // of no-op-ing and hanging runApp forever — the launch
        // watchdog in DesktopView surfaces the failure. The pid is
        // ignored when an error is set (both call sites throw on
        // error), so -1 is just a placeholder.
        guard let openWindow = openWindowAction else {
            pidCallback?(NSNumber(value: -1), "SealBox 还没准备好，请稍后再试。")
            return
        }
        openWindow(id: "appView", value: dataUUID)
    }
    
    @objc class func openExistingAppWindow(dataUUID: String) -> Bool {
        for a in appDict {
            if a.value.dataUUID == dataUUID {
                openWindowAction?(id: "appView", value: a.key)
                return true
            }
        }
        return false
    }
}

@available(iOS 16.1, *)
struct AppSceneViewSwiftUI: UIViewControllerRepresentable {
    @Binding var show: Bool
    let bundleId: String
    let dataUUID: String
    let initSize: CGSize
    let onAppInitialize: (Int32, Error?) -> Void
    
    class Coordinator: NSObject, AppSceneViewControllerDelegate {
        let onExit: () -> Void
        let onAppInitialize: (Int32, Error?) -> Void
        init(onAppInitialize: @escaping (Int32, Error?) -> Void, onExit: @escaping () -> Void) {
            self.onAppInitialize = onAppInitialize
            self.onExit = onExit
        }
        
        func appSceneVCAppDidExit(_: AppSceneViewController!) {
            onExit()
        }
        
        func appSceneVC(_ vc: AppSceneViewController!, didInitializeWithError error: (any Error)!) {
            DispatchQueue.main.async {
                (vc.view.window?.windowScene?.statusBarManager as? LCStatusBarManager)?.nativeWindowViewController = vc
            }
            onAppInitialize(vc.pid, error)
        }
        
        func appSceneVCWillActivateScene(_ vc: AppSceneViewController!) {
            vc.updateSettings { settings in
                guard let settings else { return }
                let defaultInsets = vc.view.window?.safeAreaInsets ?? .zero
                settings.peripheryInsets = defaultInsets
                settings.safeAreaInsetsPortrait = defaultInsets
                settings.deviceOrientation = UIDevice.current.orientation
                settings.setInterfaceOrientation(UIApplication.shared.statusBarOrientation)
                if(settings.interfaceOrientation().isLandscape) {
                    settings.setFrame(CGRect(x: 0, y: 0, width: vc.view.frame.size.height, height: vc.view.frame.size.width))
                } else {
                    settings.setFrame(CGRect(x: 0, y: 0, width: vc.view.frame.size.width, height: vc.view.frame.size.height))
                }
            }
            // fix live resize
            vc.contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        
        func appSceneVC(_ vc: AppSceneViewController!, didUpdateFrom settings: UIMutableApplicationSceneSettings!, transitionContext context: Any!, lifecycleActionType actionType: UInt32) {
            settings.interruptionPolicy = 0
            //settings.peripheryInsets = vc.view.window?.safeAreaInsets ?? .zero
            vc.presenter.scene.updateSettings(settings, withTransitionContext: context, completion: nil)
            // Not sure what actionType 2 is, but it's only set when this scene enters foreground, so we can pass URL scheme here
            if actionType == 2, let launchUrl = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
                UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
                vc.openURLScheme(launchUrl)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onAppInitialize: onAppInitialize, onExit: {
            show = false
            // 0.0.5: the guest is gone — drop its scene table and
            // switcher entries so the switcher never lists a dead app
            // and a later tap relaunches instead of reopening it.
            MultitaskWindowManager.removeAppWindow(dataUUID: dataUUID)
        })
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        return AppSceneViewController(bundleId: bundleId, dataUUID: dataUUID, delegate: context.coordinator)
    }
    
    func updateUIViewController(_ vc: UIViewController, context _: Context) {
        if let vc = vc as? AppSceneViewController {
            if !show {
                vc.terminate()
            }
        }
    }
}

@available(iOS 16.1, *)
struct MultitaskAppWindow: View {
    @State var show = true
    @State var pid = 0
    @State var appInfo: MultitaskAppInfo? = nil
    @State var errorMessage: String? = nil
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @Environment(\.openWindow) var openWindow
    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
    init(id: String) {
        guard let appInfo = MultitaskWindowManager.appDict[id] else {
            return
        }
        _appInfo = State(initialValue: appInfo)
    }
    
    var body: some View {
        // 0.0.7: native fullscreen is the only window mode — the
        // virtual small window and its auto-relaunch-on-terminate
        // path are gone, so a terminated guest always shows the
        // terminated screen below.
        if show, let appInfo {
            GeometryReader { geometry in
                AppSceneViewSwiftUI(show: $show, bundleId: appInfo.bundleId, dataUUID: appInfo.dataUUID, initSize: geometry.size,
                                    onAppInitialize: { pid, error in
                    DispatchQueue.main.async {
                        // 0.0.5: the scene's window is live now — make
                        // sure the switcher can snapshot it (onAppear
                        // may have run before the window was attached).
                        MultitaskWindowManager.registerSceneWindow(dataUUID: appInfo.dataUUID, window: sceneDelegate.window)
                        if error == nil {
                            self.pid = Int(pid)
                            // 0.0.6: the guest really opened now — only
                            // here does the app become "running" for
                            // the switcher. LCUtils used to register
                            // before the scene opened, so the switcher
                            // listed apps that never opened (0.0.5).
                            MultitaskDockManager.shared.addRunningApp(appInfo.displayName, appUUID: appInfo.dataUUID, view: nil)
                        } else {
                            self.errorMessage = error?.localizedDescription
                        }
                        DataManager.shared.model.pidCallback?(NSNumber(value: pid), error)
                        DataManager.shared.model.pidCallback = nil
                    }
                })
                .background(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(.all, edges: .all)
            .navigationTitle(Text("\(appInfo.displayName) - \(String(pid))"))
            .onAppear {
                // 0.0.5: register this scene's window so the switcher
                // can snapshot it for its card.
                MultitaskWindowManager.registerSceneWindow(dataUUID: appInfo.dataUUID, window: sceneDelegate.window)
            }
            .onDisappear {
                MultitaskWindowManager.unregisterSceneWindow(dataUUID: appInfo.dataUUID)
            }
            .onReceive(pub) { out in
                if let scene1 = sceneDelegate.window?.windowScene, let scene2 = out.object as? UIWindowScene, scene1 == scene2 {
                    show = false
                    // 0.0.5: the scene is gone — drop its entries so
                    // the switcher never lists a dead app.
                    MultitaskWindowManager.removeAppWindow(dataUUID: appInfo.dataUUID)
                }
            }
            
        } else {
            VStack {
                Text("lc.multitaskAppWindow.appTerminated".loc)
                    .font(.largeTitle)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(.body, design: .monospaced))
                    Button("lc.common.copy".loc) {
                        UIPasteboard.general.string = errorMessage
                        requestSceneDestruction()
                    }
                    .buttonStyle(.bordered)
                }
                Button("lc.common.close".loc) {
                    requestSceneDestruction()
                }
                .buttonStyle(.bordered)
            }.onAppear {
                // appInfo == nil indicates this is the first scene opened in this launch. We don't want this so we open lc's main scene and close this view
                // however lc's main view may already be starting in another scene so we wait a bit before opening the main view
                // also we have to keep the view open for a little bit otherwise lc will be killed by iOS
                if appInfo == nil {
                    if DataManager.shared.model.mainWindowOpened {
                        requestSceneDestruction()
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            if !DataManager.shared.model.mainWindowOpened {
                                openWindow(id: "Main")
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                requestSceneDestruction()
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func requestSceneDestruction() {
        guard let session = sceneDelegate.window?.windowScene?.session else { return }
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { error in
            print(error)
        }
    }
}
