//
//  LCSealBoxControlCenter.swift
//  LiveContainerSwiftUI
//
//  SealBox 控制中心（demo §6 重建：只含 JIT 一项）。
//
//  - 全屏面板（inset 0，padding 70/22/30），从 translateY(−103%) 以
//    0.58 s spring-sheet 滑入；JIT 行是唯一的 tile。
//  - 打开路径只剩编辑态 "···" 菜单（demo §6：没有边缘/角落手势；
//    顶部右侧 44pt 触发条已按拍板删除，LCSealBoxControlCenterTrigger
//    不再存在）。
//  - 关闭：空白处上拖（dy < −40，或 dy < −24 且 v < −0.5）、点空白处、
//    全屏上滑（dy < −40）；点锁定的横杠关 CC 由点空白处覆盖（CC 打开
//    时桌面横杠被面板盖住，见汇报）。
//  - JIT 行点按只切换本地视觉：图标圆点变暗、副标题变「已关闭」，再
//    点恢复；不改任何真实 JIT 状态、不写持久化。
//  - 没有可用的实时 JIT 状态信号：checkJITEnabled() 是 LCBootstrap.m
//    内的进程本地静态函数（csops 查本进程 CS_DEBUGGED），未暴露给
//    SwiftUI，也没有任何持久化/共享的状态位。因此副标题不编造
//    「已开启」/「未开启」——默认「完整 JIT · 由 Seal 开启」（SealBox
//    内没有 demo 那个 JIT-less 开关可镜像，见汇报）。
//
//  未编译、未真机验证（本机无 Xcode/Swift）：面板手势须真机走查。
//

import SwiftUI

// MARK: - Control centre overlay (JIT only)

struct LCSealBoxControlCenterView: View {
    /// Dismiss the overlay (tap blank, or swipe the panel up).
    var onDismiss: () -> Void

    /// The panel's drag-follow offset (demo §6: the panel follows
    /// the finger up 1:1, down at 0.25×). Zero at rest.
    @State private var dragOffset: CGFloat = 0
    /// Release velocity for the dismiss decision (demo §6).
    @State private var velocityTracker = LCVelocityTracker()
    /// Local visual toggle only (demo §6): tap the JIT tile to dim
    /// it and show "已关闭"; tap again to restore. Nothing is
    /// persisted and no real JIT state changes.
    @State private var jitOff = false
    /// Pressed tile: scale 0.96 (demo §6, 0.35 s spring-pop).
    @State private var tilePressed = false
    /// Tile stagger-in (demo §6: cc-in 0.55 s spring-pop from
    /// translateY(−16) scale(.94)).
    @State private var tileAppeared = false

    /// Demo §6 subtitle: the JIT-less variant ("JIT-less · 已就绪")
    /// has no native switch to mirror (there is no JIT-less toggle in
    /// Settings — JIT-less readiness is certificate-dependent and has
    /// no synchronous flag), so the base subtitle is the Seal-JIT one.
    private var jitSubtitle: String {
        jitOff ? "已关闭" : "完整 JIT · 由 Seal 开启"
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Full-screen panel: dim blank area + the single JIT tile.
            // The whole panel follows the drag (offset here); the drag
            // gesture itself lives on the stationary outer container
            // below, so the moving panel never feeds its own motion
            // back into the gesture.
            panelContent
                .offset(y: dragOffset)
        }
        .ignoresSafeArea()
        // Panel drag (demo §6, paths 1 + 3): attached to the outer
        // container so a swipe starting anywhere — blank area or the
        // tile — can close the panel.
        .gesture(panelDrag)
    }

    private var panelContent: some View {
        ZStack(alignment: .top) {
            // Blank area: tap closes immediately (demo §6 path 2).
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
            VStack(spacing: 0) {
                jitTile
                Spacer()
            }
            .padding(.top, 70)
            .padding(.horizontal, 22)
            .padding(.bottom, 30)
        }
    }

    /// The one wide JIT tile (demo §6): bolt icon + "JIT" + subtitle.
    /// Tap toggles the local visual only.
    private var jitTile: some View {
        Button {
            jitOff.toggle()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(jitOff ? Color(red: 120 / 255, green: 128 / 255, blue: 145 / 255).opacity(0.5) : .yellow)
                        .frame(width: 44, height: 44)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("JIT")
                        .font(.headline)
                    Text(jitSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .scaleEffect(tilePressed ? 0.96 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: tilePressed)
        .scaleEffect(tileAppeared ? 1 : 0.94)
        .offset(y: tileAppeared ? 0 : -16)
        .opacity(tileAppeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) {
                tileAppeared = true
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in tilePressed = true }
                .onEnded { _ in tilePressed = false }
        )
    }

    /// Panel drag (demo §6): the panel follows the finger — up 1:1,
    /// down damped to 0.25×. Release closes if dy < −40 (path 3: any
    /// screen swipe up past −40; this subsumes path 1's dy < −90) or
    /// if dy < −24 with a fast upward flick (path 1); anything else
    /// springs back (0.58 s spring-sheet).
    private var panelDrag: some Gesture {
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
                tilePressed = false
                if dy < -40 || (dy < -24 && vy < -0.5) {
                    onDismiss()
                } else {
                    withAnimation(.spring(response: 0.58, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
            }
    }
}
