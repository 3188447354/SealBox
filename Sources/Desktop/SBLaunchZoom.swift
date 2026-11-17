// 点图标开场缩放：从图标锚点缩到 0.12、圆角 44，460ms 等待后交由启动方接管。
import SwiftUI

/// 点图标开场动画的承载视图。无图标位置时从屏幕中心起。
/// 用法：SBDesktopView 在证书门通过后，把本视图盖在桌面上做 460ms 动画，
/// 动画结束（onFinished）后调用方再调 onLaunchApp 做真实重启。
struct SBLaunchZoom: View {
    var anchor: CGPoint?
    var onFinished: (() -> Void)?

    @State private var scale: CGFloat = 1.0
    @State private var cornerRadius: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            Color.black.opacity(0.01)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black)
                        .frame(width: geometry.size.width * scale, height: geometry.size.height * scale)
                        .position(anchor ?? CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2))
                )
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.46)) {
                        scale = 0.12
                        cornerRadius = 44
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) {
                        onFinished?()
                    }
                }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// 启动缩放的时序常量（与 SBLaunchZoom 的动画保持一致）。
enum SBLaunchZoomTiming {
    static let duration: TimeInterval = 0.46
    static let endScale: CGFloat = 0.12
    static let endCornerRadius: CGFloat = 44
}
