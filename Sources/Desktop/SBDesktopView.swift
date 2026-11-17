import SwiftUI

/// 桌面（STUB：脚手架先行版，只画壁纸与空态；完整桌面由 Desktop 模块替换）。
struct SBDesktopView: View {
    @EnvironmentObject private var store: SBStore

    var body: some View {
        ZStack {
            Image("DefaultWallpaper")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
            // 空态：没装 App 时桌面只有壁纸，无引导文案、无假数据。
            Color.clear
        }
        .onAppear {
            _ = store.loadInstalledApps()
        }
    }
}
