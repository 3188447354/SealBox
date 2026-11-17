// 控制中心面板：右上角下滑唤出，含 JIT 状态一格（只展示）。
import SwiftUI

/// 控制中心面板。JIT 一格只展示状态，不提供开关；
/// 通知中心 v1 不做——调用方在下滑手势里只做回弹 + toast。
struct SBControlCenter: View {
    /// true 显示「完整 JIT·由 Seal 开启」，false 显示「已关闭」。
    var jitEnabled: Bool = false
    var onClose: (() -> Void)?
    /// 打开设置页（调用方先关面板再推设置页）。
    var onOpenSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("控制中心")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("关闭") { onClose?() }
                    .font(.system(size: 15))
            }
            // JIT 状态一格：只展示。
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 20))
                    .foregroundColor(jitEnabled ? .yellow : .secondary)
                    .frame(width: 44, height: 44)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("JIT")
                        .font(.system(size: 15, weight: .medium))
                    Text(jitEnabled ? "完整 JIT·由 Seal 开启" : "已关闭")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // 设置入口。
            Button(action: {
                onClose?()
                onOpenSettings?()
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text("设置")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("更多控制项后续版本提供")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 8)
    }
}
