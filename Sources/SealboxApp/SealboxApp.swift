import SwiftUI

// PhoneVM home-screen shell (0.1.4): full-function build.
// Navigation: home icons open apps full-screen (slide from right);
// swipe up from the bottom bar returns home; in-app pages use NavigationStack.
@main
struct SealboxApp: App {
    @StateObject private var vm = VMState()
    @StateObject private var coordinator = SBAppCoordinator()

    var body: some Scene {
        WindowGroup {
            VMRootView()
                .environmentObject(vm)
                .environmentObject(coordinator)
        }
    }
}

struct VMRootView: View {
    @EnvironmentObject private var vm: VMState
    @EnvironmentObject private var coordinator: SBAppCoordinator
    @AppStorage("vm.appearanceDark") private var appearanceDark = true
    @AppStorage("vm.plugin.statusBarFancy") private var statusBarFancy = false
    @State private var didRouteLaunch = false
    @State private var didMigrate = false

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
            // 桌面先读一次 SBStore（单源头），再跑启动路由与旧记录迁移。
            SBStore.shared.loadInstalledApps()
            // 启动路由只跑一次：重起进客 App 时兑现收据加载客 App，
            // 过期 restart-requested 收据记失败、残留 guest-loaded 收据静默清除。
            // 路由跑完立刻按收据弹一次错（收据随即清除，不重复弹）。
            if !didRouteLaunch {
                didRouteLaunch = true
                SBLaunchRouter.routeOnLaunchIfNeeded()
                coordinator.showGuestFailedReceiptIfNeeded()
            }
            // 旧记录迁移只跑一次：后台线程重解析 Documents/IPAs，跑完刷新 SBStore。
            if !didMigrate {
                didMigrate = true
                Task {
                    await SBMigration.migrateIfNeeded()
                    await MainActor.run {
                        SBStore.shared.loadInstalledApps()
                    }
                }
            }
        }
        // 协调器弹窗：阶段名作标题、中文原因作正文；证书门拦截给“去导入证书”。
        .alert(item: $coordinator.activeAlert) { alert in
            if alert.goToSettings {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("去导入证书")) {
                        vm.openApp = .settings
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        // 同名三选一 sheet（不用 confirmationDialog 的 item 形态）。
        .sheet(item: $coordinator.duplicatePending) { pending in
            VStack(spacing: 20) {
                Text("已经安装过“\(pending.existing.displayName)”")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("同一 Bundle ID（\(pending.existing.bundleID)）已装过，请选择如何处理。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("替换（保留旧数据）") {
                    coordinator.resolveDuplicate(replace: true)
                }
                .buttonStyle(.borderedProminent)
                Button("平行安装（新装一份）") {
                    coordinator.resolveDuplicate(replace: false)
                }
                .buttonStyle(.bordered)
                Button("取消", role: .cancel) {
                    coordinator.cancelDuplicate()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .presentationDetents([.medium])
        }
        // 删除失败弹错（桌面不动）。
        .alert(
            "删除失败",
            isPresented: Binding(
                get: { coordinator.deleteError != nil },
                set: { newValue in
                    if !newValue {
                        coordinator.deleteError = nil
                    }
                }
            ),
            presenting: coordinator.deleteError
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { error in
            Text(error.localizedDescription)
        }
    }

    @ViewBuilder
    private func appView(_ app: VMApp) -> some View {
        switch app {
        case .settings: SettingsView()
        case .source: SourceView()
        case .plugins: PluginsView()
        case .installed(let recordID): InstalledAppDetailView(recordID: recordID)
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
