//
//  LCSealBoxControlCenter.swift
//  LiveContainerSwiftUI
//
//  SealBox 控制中心（开发文档 §13：控制中心只保留 JIT 一项）。
//
//  - 浮层样式：仅含 JIT，不堆其他开关。
//  - 触发：从屏幕右上边缘下滑（仿 iOS 控制中心手势）。触发区是顶部
//    44pt 高、右端 160pt 宽的窄条，位于状态栏区域，与编辑模式胶囊、
//    锁按钮均不重叠（两者都在安全区下方）；经核对，桌面现有手势里
//    没有与之冲突的（TabView 翻页是横向的，系统页左滑在 cover 内）。
//  - 只显示真实 JIT 状态：配置的 JIT 方式取自 App Group 默认值里的
//    LCJITEnablerType（与设置页同一来源）；「由 Seal 开启」入口打开
//    已有的设置页 JIT 分区（上游既有界面），不在 SealBox 内新建开启器。
//  - 没有可用的实时 JIT 状态信号：checkJITEnabled() 是 LCBootstrap.m
//    内的进程本地静态函数（csops 查本进程 CS_DEBUGGED），未暴露给
//    SwiftUI，也没有任何持久化/共享的状态位。因此状态行只显示中性
//    空状态「暂无运行状态」，绝不编造「已开启」/「未开启」。
//    Seal 侧入口的设计见汇报，不在本文件写代码。
//
//  未编译、未真机验证（本机无 Xcode/Swift）：触发手势须真机走查。
//

import SwiftUI

// MARK: - JIT status (SealBox side: receive / display only)

/// Reads the real configured JIT enabler. The live "is JIT on right
/// now" state has no reliable signal in this process (see the file
/// header), so the UI shows a neutral empty state instead of inventing one.
enum LCSealBoxJITStatus {
    /// The configured JIT enabler, from the same App Group key the
    /// Settings page reads (LCJITEnablerType). "未设置" only when the
    /// stored raw value matches no known enabler.
    static var enablerName: String {
        let raw = LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")
        return JITEnablerType(rawValue: raw)?.displayName ?? "未设置"
    }

    /// Neutral empty state: no live JIT signal exists to report.
    static var liveStateText: String {
        "暂无运行状态"
    }
}

// MARK: - Control centre trigger (swipe down from the top-right edge)

/// Invisible trigger zone: the top 44pt strip at the trailing edge.
/// It sits above the status bar area, clear of the edit-mode capsules
/// and the lock button (both live below the safe area). A mostly-downward
/// drag longer than 40pt opens the control centre.
struct LCSealBoxControlCenterTrigger: View {
    var onTrigger: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 160, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        if value.translation.height > 40,
                           value.translation.height > abs(value.translation.width) {
                            onTrigger()
                        }
                    }
            )
    }
}

// MARK: - Control centre overlay (JIT only)

struct LCSealBoxControlCenterView: View {
    /// Dismiss the overlay (tap outside, or swipe the panel up).
    var onDismiss: () -> Void
    /// "由 Seal 开启" entry: the caller hides the overlay and opens
    /// the Settings page (its existing JIT section).
    var onOpenSettings: () -> Void

    /// The panel's drag-follow offset (demo §6: the panel follows
    /// the finger up 1:1, down at 0.25×). Zero at rest.
    @State private var dragOffset: CGFloat = 0
    /// Release velocity for the dismiss decision (demo §6).
    @State private var velocityTracker = LCVelocityTracker()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                // Swipe up on the dim area dismisses too (demo §6
                // path 3): a mostly-upward drag ending past −40pt.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            if value.translation.height < -40 {
                                onDismiss()
                            }
                        }
                )
            VStack(alignment: .leading, spacing: 0) {
                Text("JIT")
                    .font(.headline)
                    .padding(.bottom, 4)
                HStack {
                    Text("方式")
                        .font(.subheadline)
                    Spacer()
                    Text(LCSealBoxJITStatus.enablerName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 6)
                Divider()
                HStack {
                    Text("状态")
                        .font(.subheadline)
                    Spacer()
                    Text(LCSealBoxJITStatus.liveStateText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 6)
                Divider()
                Button {
                    onOpenSettings()
                } label: {
                    HStack {
                        Text("由 Seal 开启")
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                Text("JIT 由 Seal 开启，SealBox 内不另设开启器。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(width: 300)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding(.top, 12)
            .padding(.trailing, 16)
            .offset(y: dragOffset)
            // Panel drag (demo §6): the panel follows the finger —
            // up 1:1, down damped to 0.25×. Release past −90pt, or
            // past −24pt with a fast upward flick, dismisses it;
            // anything else springs back (0.58 s spring-sheet).
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        velocityTracker.record(CGPoint(x: value.translation.width, y: value.translation.height))
                        let dy = value.translation.height
                        dragOffset = dy < 0 ? dy : dy * 0.25
                    }
                    .onEnded { value in
                        let dy = value.translation.height
                        let vy = velocityTracker.velocity.dy
                        velocityTracker.reset()
                        if dy < -90 || (dy < -24 && vy < -0.5) {
                            onDismiss()
                        } else {
                            withAnimation(.spring(response: 0.58, dampingFraction: 0.8)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
        }
    }
}
