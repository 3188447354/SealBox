// 底部 Home Indicator 区域：仅视觉占位与安全区处理，桌面态轻触无动作。
import SwiftUI

/// Home Indicator 占位条。桌面态轻触无动作，不拦截、不触发任何操作。
struct SBHomeBar: View {
    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.9))
            .frame(width: 134, height: 5)
            .padding(.bottom, 8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
