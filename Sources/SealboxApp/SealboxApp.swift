import SwiftUI

/// Sealbox 新产品入口：进应用就是手机系统 UI（桌面），只做 IPA 导入、桌面启动。
@main
struct SealboxApp: App {
    @StateObject private var store = SBStore.shared

    init() {
        // 进程启动时先判断：是回桌面，还是进上次选中的客 App。
        SBLaunchRouter.routeOnLaunchIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            SBDesktopView()
                .environmentObject(store)
        }
    }
}
