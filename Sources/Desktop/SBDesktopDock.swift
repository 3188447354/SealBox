// 底部 Dock：4 位、毛玻璃、圆角 30，支持拖入拖出。
import SwiftUI

/// Dock 视图。内容由调用方传入（SBDesktopView 按 SBDesktopDockOrder 排序后给入）；
/// 拖入/拖出只回调，不直接改 SBStore，落位持久化由调用方负责。
struct SBDesktopDock: View {
    let apps: [SBInstalledApp]
    var isEditing: Bool = false
    var draggedBundleID: String?
    var onTap: ((SBInstalledApp) -> Void)?
    var onLongPress: ((SBInstalledApp) -> Void)?
    var onDeleteTap: ((SBInstalledApp) -> Void)?
    /// 图标被拖进 Dock 区域（调用方据此把该 App 移入 Dock，最多 4 位）。
    var onDropIntoDock: ((SBInstalledApp) -> Void)?
    /// 图标被从 Dock 拖出到桌面（调用方据此把该 App 移回桌面网格）。
    var onDragOutOfDock: ((SBInstalledApp) -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            ForEach(apps.prefix(4), id: \.bundleID) { app in
                SBDesktopCell(
                    app: app,
                    iconSize: 60,
                    isEditing: isEditing,
                    isGhost: draggedBundleID == app.bundleID,
                    onTap: { onTap?(app) },
                    onDeleteTap: { onDeleteTap?(app) },
                    onLongPress: { onLongPress?(app) }
                )
            }
            // 不足 4 位时留空位，保持 Dock 宽度稳定；空位本身不可点。
            ForEach(0..<(4 - min(apps.count, 4)), id: \.self) { _ in
                Color.clear.frame(width: 60, height: 60)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .onDrop(of: [.text], isTargeted: nil) { providers in
            // 拖入 Dock：只认本桌面拖出的 bundleID 文本，外部拖入不接受。
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let bundleID = object as? String,
                      let app = apps.first(where: { $0.bundleID == bundleID }) ?? SBStore.shared.app(with: bundleID) else { return }
                DispatchQueue.main.async {
                    onDropIntoDock?(app)
                }
            }
            // 同步返回 true 表示接受本次放下，具体移入由上面的回调完成。
            return true
        }
    }
}
