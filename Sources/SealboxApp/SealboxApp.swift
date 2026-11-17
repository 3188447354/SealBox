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
    }

    @ViewBuilder
    private func appView(_ app: VMApp) -> some View {
        switch app {
        case .settings: SettingsView()
        case .source: SourceView()
        case .plugins: PluginsView()
        case .installed(let name): InstalledAppDetailView(name: name)
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
