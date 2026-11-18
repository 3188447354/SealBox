import SwiftUI
import LocalAuthentication

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
    @AppStorage("vm.settings.passcode") private var passcode = ""
    @AppStorage("vm.settings.faceID") private var faceIDOn = false
    @State private var didRouteLaunch = false
    @State private var didMigrate = false
    @State private var didDecideLock = false
    @State private var didSeedCheck = false
    @State private var didEnsureHooks = false
    @State private var showLock = false
    @State private var unlocked = false

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

            // 密码锁（0.2.1）：盖在最上层；解锁前桌面和各应用页都点不到。
            if showLock && !unlocked {
                VMLockView(passcode: passcode, faceIDOn: faceIDOn) {
                    unlocked = true
                }
                .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: vm.openApp)
        .preferredColorScheme(appearanceDark ? .dark : .light)
        .statusBar(hidden: statusBarFancy)
        .overlay(alignment: .bottom) { homeSwipeZone }
        .onAppear {
            // 0.2.1：删掉的“自定义手势”开关在旧手机上还留着一个死值，清掉。
            UserDefaults.standard.removeObject(forKey: "vm.plugin.customGestures")
            // 密码锁的决定必须在启动路由之前做：路由会消费重起收据，
            // 之后再查 isGuestLaunchRequested 就永远是 false，锁会错挡客 App。
            let guestLaunchPending = SBGuestLoader.isGuestLaunchRequested()
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
            // 密码锁（0.2.1）：设了密码才锁；重起进客 App 的那次启动不锁，
            // 否则客 App 出不来。只决定一次，解锁状态跟随本次进程。
            if !didDecideLock {
                didDecideLock = true
                if !passcode.isEmpty && !guestLaunchPending {
                    showLock = true
                }
            }
            // 种子应用（0.2.1：Via）：后台装一次，不阻塞启动；装完桌面刷新。
            if !didSeedCheck {
                didSeedCheck = true
                Task {
                    await SBSeedApps.installIfNeeded(coordinator: coordinator)
                }
            }
            // 注入件签名（0.2.2）：启动时后台尽力而为一次——保证 Tweaks 里的
            // SBGuestHooks.dylib 带着当前证书的 Team；失败不弹错（点图标启动前
            // 与自测里还会再拦一次），只让件提前就位。
            if !didEnsureHooks {
                didEnsureHooks = true
                Task.detached {
                    _ = await SBCertificate.ensureHooksDylibSigned()
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
            if alert.goToDesktop {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("去看看")) {
                        vm.homePage = 1
                        vm.openApp = nil
                    },
                    secondaryButton: .cancel(Text("留在软件源"))
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

// MARK: - 密码锁（0.2.1）

/// 设了虚拟机密码后，每次冷启动都要输密码才能进桌面；面容 ID 开关开着时，
/// 可用本机面容 ID 解锁。重起进客 App 时不显示（VMRootView 在 onAppear 里、
/// 启动路由之前决定 showLock）。输错只报错不锁死；忘密码只能删 App 重装
/// （密码存在本机 UserDefaults，删 App 即清）。
private struct VMLockView: View {
    let passcode: String
    let faceIDOn: Bool
    let onUnlock: () -> Void
    @State private var entry = ""
    @State private var error = ""
    @State private var faceIDError = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                Text("输入密码")
                    .font(.title3)
                    .foregroundStyle(.white)
                HStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(index < entry.count ? Color.white : Color.white.opacity(0.4))
                            .frame(width: 14, height: 14)
                    }
                }
                if !error.isEmpty {
                    Text(error)
                        .foregroundStyle(.red)
                }
                keypad
                if faceIDOn {
                    Button("使用面容 ID") {
                        authenticateWithFaceID()
                    }
                    .foregroundStyle(.white)
                    if !faceIDError.isEmpty {
                        Text(faceIDError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
            }
        }
    }

    private var keypad: some View {
        let keys: [[String]] = [
            ["1", "2", "3"],
            ["4", "5", "6"],
            ["7", "8", "9"],
            ["", "0", "⌫"],
        ]
        return VStack(spacing: 16) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 28) {
                    ForEach(row, id: \.self) { key in
                        if key.isEmpty {
                            Color.clear.frame(width: 64, height: 64)
                        } else if key == "⌫" {
                            Button {
                                if !entry.isEmpty { entry.removeLast() }
                            } label: {
                                Image(systemName: "delete.left.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.white)
                                    .frame(width: 64, height: 64)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button { pressDigit(key) } label: {
                                Text(key)
                                    .font(.system(size: 28, weight: .light))
                                    .foregroundStyle(.white)
                                    .frame(width: 64, height: 64)
                                    .background(Color.white.opacity(0.15), in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func pressDigit(_ digit: String) {
        guard entry.count < 4 else { return }
        entry.append(digit)
        guard entry.count == 4 else { return }
        if entry == passcode {
            error = ""
            onUnlock()
        } else {
            error = "密码不对"
            entry = ""
        }
    }

    private func authenticateWithFaceID() {
        let context = LAContext()
        var evalError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: &evalError) else {
            faceIDError = "本机面容 ID 不可用"
            return
        }
        Task {
            do {
                let ok = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "解锁虚拟机")
                if ok {
                    await MainActor.run { onUnlock() }
                }
            } catch let error as LAError where error.code == .userCancel {
                // 用户取消，不报错。
            } catch {
                await MainActor.run { faceIDError = "面容 ID 验证失败" }
            }
        }
    }
}
