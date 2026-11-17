import SwiftUI

/// Sealbox 新产品入口：进应用就是手机系统 UI（桌面），只做 IPA 导入、桌面启动。
@main
struct SealboxApp: App {
    @StateObject private var store = SBStore.shared
    @StateObject private var coordinator = SBAppCoordinator()

    init() {
        // 进程启动时先判断：是回桌面，还是进上次选中的客 App。
        SBLaunchRouter.routeOnLaunchIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            SBDesktopView(
                installProgress: coordinator.installProgress,
                jitEnabled: SBGuestLoader.isJITEnabled(),
                onLaunchApp: { coordinator.launchApp($0) },
                onDeleteApp: { coordinator.deleteApp($0) },
                onNeedCertificate: { coordinator.importCertificate() },
                onImport: { coordinator.importIPA() },
                onOpenSettings: { coordinator.showingSettings = true },
                deleteError: coordinator.deleteError
            )
            .environmentObject(store)
            .onAppear {
                SBStore.shared.loadInstalledApps()
                coordinator.showGuestFailedReceiptIfNeeded()
            }
            .sheet(isPresented: $coordinator.showingSettings) {
                NavigationView {
                    SBSettingsView(
                        apps: SBStore.shared.loadInstalledApps(),
                        jitEnabled: SBGuestLoader.isJITEnabled()
                    )
                    .navigationTitle("设置")
                }
            }
            .alert(item: $coordinator.activeAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("知道了"))
                )
            }
            .sheet(item: $coordinator.duplicatePending) { pending in
                // 同名选择：替换 / 平行安装 / 取消（用 sheet，不用 confirmationDialog 的 item 形态）。
                VStack(alignment: .leading, spacing: 16) {
                    Text("已安装此应用")
                        .font(.system(size: 20, weight: .semibold))
                    Text("“\(pending.existing.displayName)”已有 \(pending.existing.version) 版。替换会保留原应用的数据，平行安装会另存一份。")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                    Button("替换已安装的版本") {
                        coordinator.resolveDuplicate(replace: true)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("平行安装一个新版本") {
                        coordinator.resolveDuplicate(replace: false)
                    }
                    .buttonStyle(.bordered)
                    Button("取消", role: .cancel) {
                        coordinator.duplicatePending = nil
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .padding(20)
            }
        }
    }
}
