// 桌面图标格：图标、名字、按压缩放与编辑态删除角标。
import SwiftUI

/// 图标缓存读取：用记录的磁盘目录（平行安装带时间戳后缀），不按 Bundle ID 猜路径。
enum SBDesktopIconProvider {
    static func iconImage(app: SBInstalledApp) -> UIImage? {
        UIImage(contentsOfFile: app.iconURL.path)
    }
}

/// 单个桌面图标格。网格 58pt，Dock 60pt（由调用方传入 iconSize）。
struct SBDesktopCell: View {
    let app: SBInstalledApp
    var iconSize: CGFloat = 58
    var isEditing: Bool = false
    var isPlaceholder: Bool = false
    var isGhost: Bool = false
    var onTap: (() -> Void)?
    var onDeleteTap: (() -> Void)?
    var onLongPress: (() -> Void)?

    @State private var isPressed: Bool = false
    @State private var pressStartLocation: CGPoint?
    @State private var pressWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 4) {
                iconView
                Text(displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
                    .frame(width: iconSize + 16)
            }
            .opacity(isPlaceholder ? 0 : 1)
            .scaleEffect(isGhost ? SBDesktopDragState.ghostScale : (isPressed ? 0.86 : 1.0))
            .shadow(color: isGhost ? .black.opacity(0.35) : .clear, radius: isGhost ? 12 : 0, x: 0, y: 6)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPressed)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isGhost)

            if isEditing {
                Button(action: { onDeleteTap?() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .offset(x: -8, y: -8)
            }
        }
        .contentShape(Rectangle())
        .gesture(pressGesture)
        .onLongPressGesture(minimumDuration: SBDesktopDragState.longPressDuration) {
            onLongPress?()
        }
    }

    private var displayName: String {
        // 显示名覆盖优先（SBDisplayNameOverrides 由详情页重命名写入）。
        let suite = "group." + (Bundle.main.bundleIdentifier ?? "")
        let overrides = UserDefaults(suiteName: suite)?.dictionary(forKey: "SBDisplayNameOverrides") as? [String: String]
        return overrides?[app.bundleID] ?? app.displayName
    }

    private var iconView: some View {
        Group {
            if let uiImage = SBDesktopIconProvider.iconImage(app: app) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: iconSize * 0.2667, style: .continuous)
                        .fill(Color.white.opacity(0.25))
                    Image(systemName: "app.fill")
                        .font(.system(size: iconSize * 0.45))
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: iconSize, height: iconSize)
        .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.2667, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
    }

    /// 按压手势：80ms 内缩到 0.86，松开 spring 回弹；移动超过 9pt 取消按压。
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pressStartLocation == nil {
                    pressStartLocation = value.startLocation
                    let workItem = DispatchWorkItem { isPressed = true }
                    pressWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
                } else if let start = pressStartLocation {
                    let moved = hypot(value.location.x - start.x, value.location.y - start.y)
                    if moved > SBDesktopDragState.pressCancelDistance {
                        pressWorkItem?.cancel()
                        pressWorkItem = nil
                        isPressed = false
                    }
                }
            }
            .onEnded { value in
                pressWorkItem?.cancel()
                pressWorkItem = nil
                isPressed = false
                pressStartLocation = nil
                // 未移动的轻点才算点按（即使短于 80ms、缩放还没来得及出现）；拖动由父视图接管。
                let moved = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                if moved <= SBDesktopDragState.pressCancelDistance {
                    onTap?()
                }
            }
    }
}
