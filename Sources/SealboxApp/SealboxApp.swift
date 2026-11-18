import SwiftUI

// PhoneVM home-screen shell (0.1.4): full-function build.
// Navigation: home icons open apps full-screen (slide from right);
// swipe up from the bottom bar returns home; in-app pages use NavigationStack.
@main
struct SealboxApp: App {
    @StateObject private var vm = VMState()

    var body: some Scene {
        WindowGroup {
            VMRootView()
                .environmentObject(vm)
        }
    }
}

struct VMRootView: View {
    @EnvironmentObject private var vm: VMState
    @AppStorage("vm.appearanceDark") private var appearanceDark = true
    @AppStorage("vm.plugin.statusBarFancy") private var statusBarFancy = false
    @State private var didRouteLaunch = false

    var body: some View {
        ZStack {
            HomeScreenView()

            if let app = vm.openApp {
                appView(app)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .trailing)
                    ))
                    .zIndex(1)
            }

            if statusBarFancy {
                FancyStatusBar()
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: vm.openApp)
        .preferredColorScheme(appearanceDark ? .dark : .light)
        .statusBar(hidden: statusBarFancy)
        .overlay(alignment: .bottom) { homeSwipeZone }
        .onAppear {
            // 启动路由只跑一次：重起进客 App 时兑现收据加载客 App，
            // 过期 restart-requested 收据记失败、残留 guest-loaded 收据静默清除。
            // 收据弹错弹窗的 UI 接线在步骤 8，本步只保证路由跑起来。
            if !didRouteLaunch {
                didRouteLaunch = true
                SBLaunchRouter.routeOnLaunchIfNeeded()
            }
        }
    }

    @ViewBuilder
    private func appView(_ app: VMApp) -> some View {
        switch app {
        case .settings: SettingsView()
        case .source: SourceView()
        case .plugins: PluginsView()
        case .installed(let name): InstalledAppDetailView(name: name)
        case .phone: PhoneAppView()
        case .safari: SafariAppView()
        case .messages: MessagesAppView()
        case .music: MusicAppView()
        }
    }

    /// Bottom 28pt strip: swipe up returns to the home screen.
    /// No tappable control may sit in the bottom 28pt of any app page.
    private var homeSwipeZone: some View {
        Color.clear
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if value.translation.height < -60 {
                            vm.openApp = nil
                        }
                    }
            )
    }
}
