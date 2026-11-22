import SwiftUI
import LocalAuthentication

// PhoneVM home-screen shell (0.1.4): full-function build.
// Navigation: home icons open apps full-screen (slide from right);
// swipe up from the bottom bar returns home; in-app pages use NavigationStack.
// 0.2.25：@main 已移走，入口在同目录的 main.m——客 App 必须在干净进程里跑
// 第一遍 UIApplicationMain（LC 同款做法，见 main.m 文件头），所以 main.m
// 要先判断有无客启动收据；无收据时调下面的 SBHostAppMain() 跑宿主 SwiftUI。
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

/// 宿主 UI 入口（供 ObjC main.m 调用）。`SealboxApp.main()` 即 SwiftUI 的
/// App 入口（内部调第一遍 UIApplicationMain），只能在确认本次进程不跑客
/// App 时调——main.m 已先分流。
@_cdecl("SBHostAppMain")
public func SBHostAppMain() {
    // 0.2.40：App 入口行——与 main.m 调用前一行夹住“窗口补丁行→读已装应用”段。
    SBDiagLog.log("宿主启动：进 SealboxApp")
    SealboxApp.main()
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
    /// 0.2.44（问题 3）：切换器呈现——桌面按钮与客内横杠长按都发
    /// SBGuestSwitcherRequested 通知，VMRootView 接到即弹切换器。
    @State private var showSwitcher = false
    /// 0.2.44（问题 1）：左边缘手势单次触发旗标（onChanged 会连发，
    /// 触发一次后置真、onEnded 复位）。
    @State private var edgeSwipeFired = false

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
        // 0.2.44（问题 1）：宿主侧左边缘手势——与客内同口径（16pt 宽 ×
        // 底部 160pt 高，右滑 ≥40pt 或 predictedEnd ≥40pt 即回桌面）。
        // 只在宿主页面打开时挂（桌面时不挂，不抢 TabView 的翻页手势）。
        .overlay(alignment: .bottomLeading) {
            if vm.openApp != nil {
                leftEdgeSwipeZone
            }
        }
        // 0.2.37：安装完成不弹提示，改为直接回桌面第 2 页看新图标
        //（通知来自 SBAppCoordinator.runInstall 成功路）。
        .onReceive(NotificationCenter.default.publisher(for: .SBInstallCompleted)) { _ in
            vm.homePage = 1
            vm.openApp = nil
        }
        // 0.2.44（问题 3）：切换器请求（桌面“切换器”按钮／客内横杠长按）
        // → 弹切换器。无后台客时切换器只显示空态，不弹错。
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name(SBGuestSwitcherRequestedNotification))) { _ in
            showSwitcher = true
        }
        .sheet(isPresented: $showSwitcher) {
            GuestSwitcherView()
        }
        .onAppear {
            // 0.2.44（F3 计量）：首帧行——VMRootView 出现即首帧已上屏；
            // 与“进 SealboxApp”行相减即启动空白段耗时。
            SBDiagLog.log("首帧：VMRootView 出现")
            // 0.2.1：删掉的“自定义手势”开关在旧手机上还留着一个死值，清掉。
            UserDefaults.standard.removeObject(forKey: "vm.plugin.customGestures")
            // 密码锁的决定必须在启动路由之前做：路由会消费重起收据，
            // 之后再查 isGuestLaunchRequested 就永远是 false，锁会错挡客 App。
            let guestLaunchPending = SBGuestLoader.isGuestLaunchRequested()
            // 桌面先读一次 SBStore（单源头），再跑启动路由与旧记录迁移。
            SBDiagLog.log("读已装应用")
            SBStore.shared.loadInstalledApps()
            // 启动路由只跑一次：重起进客 App 时兑现收据加载客 App，
            // 过期 restart-requested 收据记失败、残留 guest-loaded 收据静默清除。
            // 路由跑完立刻按收据弹一次错（收据随即清除，不重复弹）。
            if !didRouteLaunch {
                didRouteLaunch = true
                SBDiagLog.log("启动路由开始")
                // 0.2.13：重启路需要异步修复时，修复完成后按收据弹错
                //（同步路照常在 route 返回后弹，见下一行）。
                SBLaunchRouter.routeOnLaunchIfNeeded {
                    coordinator.showGuestFailedReceiptIfNeeded()
                }
                SBDiagLog.log("启动路由完成")
                coordinator.showGuestFailedReceiptIfNeeded()
                // 0.2.26 G6/G9：上次未捕获异常、安装中途崩溃各弹一次（读到即清）。
                coordinator.showLastLaunchErrorIfNeeded()
                coordinator.showSigningCrashIfNeeded()
            }
            // 旧记录迁移只跑一次：后台线程重解析 Documents/IPAs，跑完刷新 SBStore。
            if !didMigrate {
                didMigrate = true
                Task {
                    SBDiagLog.log("迁移开始")
                    await SBMigration.migrateIfNeeded()
                    SBDiagLog.log("迁移完成")
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
                    SBDiagLog.log("密码锁：已设置，显示锁屏")
                } else {
                    SBDiagLog.log("密码锁：未设置或客启动，不锁")
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
                    SBDiagLog.log("注入件签名检查开始")
                    let ok = await SBCertificate.ensureHooksDylibSigned()
                    SBDiagLog.log("注入件签名检查完成：\(ok ? "已就位" : "失败（不拦启动）")")
                }
            }
            SBDiagLog.log("界面出现")
            SBDiagLog.markStartupComplete()
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
            if let appToDelete = alert.deleteApp {
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .destructive(Text("删除该应用")) {
                        coordinator.deleteApp(appToDelete)
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
    /// 0.2.44（问题 1）：阈值与客内横杠对齐——上滑 ≥32pt 或 predictedEnd
    /// < −32pt（快滑的速度代理）即触发，onChanged 即时触发，不等手指抬起。
    /// 旧阈值是抬起后 translation < −60pt（慢滑、长滑才回得去）。
    private var homeSwipeZone: some View {
        Color.clear
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        if value.translation.height <= -32 || value.predictedEndTranslation.height <= -32 {
                            vm.openApp = nil
                        }
                    }
            )
    }

    /// 0.2.44（问题 1）：宿主侧左边缘手势——16pt 宽 × 底部 160pt 高，
    /// 与客内 SBHomeBarOverlay 的左边缘区同口径（右滑 ≥40pt 或
    /// predictedEnd ≥40pt；SwiftUI DragGesture 没有速度值，predictedEnd
    /// 是速度推导的近似代理）。单次触发（onChanged 连发时只触发一次）。
    private var leftEdgeSwipeZone: some View {
        Color.clear
            .frame(width: 16, height: 160)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard !edgeSwipeFired else { return }
                        if value.translation.width >= 40 || value.predictedEndTranslation.width >= 40 {
                            edgeSwipeFired = true
                            vm.openApp = nil
                        }
                    }
                    .onEnded { _ in
                        edgeSwipeFired = false
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
