//
//  LCSealBoxHomeBar.swift
//  LiveContainerSwiftUI
//
//  SealBox 应用锁与底部横杠（demo §8 重建；开发文档 §11 定稿、§14 动画规范）。
//
//  定稿规则（demo §8）：
//  - 虚拟横杠只在「锁定且有 App 打开」时出现（bottom 118px，Dock 上方）；
//    桌面上没有任何可见横杠，只有一条看不见的命中条。
//  - 锁按钮 40×40、右 14、下 118，只在 App 打开时显示；状态只靠
//    闭锁/开锁图标区分，无发光。
//  - 手势只在锁定时接管；未锁定完全不响应、不误触真机。
//  - 上滑快甩回桌面（up > 22% 屏高，或 v < -0.55 且 up > 26px）；
//    上滑停顿进切换器（静止 > 60ms 且 up 在 30px–62% 屏高）；
//    按住 0.42s（移动 < 14px）进切换器；双击（两击 < 380ms）进切换器。
//  - 跟随按比例缩小（scale 1 − p·0.22，p = up / (H·0.5)）；圆角只在
//    0 / 22 / 38 三档切换；命中区下沿距屏幕底部 36px 封顶。
//  - 进切换器与回桌面是同一条连续手势流，不分段跳变。
//  - 手势被系统打断时，窗口必须回落到进入手势前的完整状态。
//  - 动画只写 transform / opacity；手势采样与样式写入按帧合并（§14）。
//
//  与 demo 的已知偏差（原生结构所限）：
//  - 桌面命中条放在 Dock 正上方（下沿约 118px，高 34px、宽
//    max(280px, 76% 屏宽），而不是 demo 的屏底 36–70px 一带——原生
//    Dock 本身占了屏底约 118px，条子不能压在 Dock 图标上；「不进
//    屏底 36px 系统手势区」这一条仍满足。
//  - 双击用手动计时（两击 < 380ms），不用系统 double-tap 识别器，
//    以便与 demo 的 380ms 精确对齐。
//
//  诚实边界（§11 无法绕过的架构事实）：经典模式下客 App 运行时容器 UI
//  不在，SwiftUI 手势伸不进客 App 进程——本文件的横杠只覆盖桌面与系统页
//  （与容器 UI 同一个窗口）；客 App 内的回桌面仍走 TweakLoader 的悬浮
//  按钮路径（UIKit+GuestHooks.m），见汇报。不要把本文件说成客 App 内手势。
//
//  事件不用闭包回传（避免 state 对象与 View 之间的保留环）：状态机只
//  写 @Published pendingAction，调用方用 .onChange(of:) 响应并清掉。
//
//  未编译、未真机验证（本机无 Xcode/Swift）：手势类必须真机走查。
//

import SwiftUI
import UIKit

// MARK: - §14 frame sampler (sample on the event, write once per frame)

/// The §14 mechanism, shared by the home bar and the app switcher:
/// gesture callbacks only record the latest translation; a CADisplayLink
/// publishes it to the onFrame closure once per frame, so style writes
/// never happen per-event.
final class LCFrameSampler: NSObject {
    private(set) var latest = CGPoint.zero
    private var link: CADisplayLink?
    var onFrame: ((CGPoint) -> Void)?

    func record(_ point: CGPoint) {
        latest = point
    }

    func start() {
        guard link == nil else {
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        onFrame?(latest)
    }

    deinit {
        stop()
    }
}

// MARK: - Velocity tracker (shared gesture helper)

/// Velocity from the last few gesture samples, in pt/ms. The home bar,
/// the switcher and the Control Center all need the release velocity;
/// SwiftUI's DragGesture gives predictedEndTranslation, not the actual
/// velocity, so this tracker records the samples itself. The velocity
/// is the most recent movement (last two samples), matching the demo's
/// per-pointermove velocity.
final class LCVelocityTracker {
    private struct Sample {
        var point: CGPoint
        var time: CFTimeInterval
    }

    private var samples: [Sample] = []

    /// Records a sample (the drag translation or location — the
    /// derivative is the same for both). Keeps the last 6 samples.
    func record(_ point: CGPoint, at time: CFTimeInterval = CACurrentMediaTime()) {
        samples.append(Sample(point: point, time: time))
        if samples.count > 6 {
            samples.removeFirst(samples.count - 6)
        }
    }

    /// The velocity over the most recent samples, in pt/ms. (0, 0)
    /// when fewer than 2 samples or no time elapsed.
    var velocity: CGVector {
        guard samples.count >= 2 else {
            return CGVector(dx: 0, dy: 0)
        }
        let first = samples[samples.count - 2]
        let last = samples[samples.count - 1]
        let dt = (last.time - first.time) * 1000
        guard dt > 0 else {
            return CGVector(dx: 0, dy: 0)
        }
        return CGVector(
            dx: (last.point.x - first.point.x) / CGFloat(dt),
            dy: (last.point.y - first.point.y) / CGFloat(dt)
        )
    }

    func reset() {
        samples.removeAll()
    }
}

// MARK: - Lock store (single source of truth, App Group defaults)

/// Whether SealBox owns the bottom home-indicator gestures. Persisted in
/// the App Group defaults under one key, one writer (the lock button).
final class LCSealBoxLockStore: ObservableObject {
    static let lockKey = "LCSealBoxHomeLocked"

    @Published var isLocked: Bool {
        didSet {
            LCUtils.appGroupUserDefault.set(isLocked, forKey: Self.lockKey)
        }
    }

    init() {
        self.isLocked = LCUtils.appGroupUserDefault.bool(forKey: Self.lockKey)
    }
}

// MARK: - Home bar state machine (one continuous gesture stream)

enum LCSealBoxHomeBarAction: Equatable {
    case goDesktop
    case openSwitcher
}

final class LCSealBoxHomeBarState: ObservableObject {
    /// Desktop hit strip (demo §8.3): 34pt tall, centred, width
    /// max(280pt, 76% of screen width). It sits directly above the
    /// Dock (see the file header for why it is not at the screen
    /// bottom); its bottom edge never enters the bottom-36pt system
    /// gesture zone.
    static let desktopStripHeight: CGFloat = 34
    static let desktopStripMinWidth: CGFloat = 280
    static let desktopStripWidthFraction: CGFloat = 0.76
    /// Virtual bar position (demo §8.2): the capsule's bottom edge
    /// sits 118pt above the screen bottom, above the Dock.
    static let virtualBarBottomOffset: CGFloat = 118
    /// Virtual bar hit area (demo §8.3): the capsule expanded by
    /// 44pt left/right, 28pt up, 22pt down.
    static let virtualBarHitExpandHorizontal: CGFloat = 44
    static let virtualBarHitExpandTop: CGFloat = 28
    static let virtualBarHitExpandBottom: CGFloat = 22
    /// Double-tap on the bar (demo §8.3): two taps < 380 ms apart.
    static let doubleTapMaxInterval: TimeInterval = 0.38
    /// Press-and-hold on the bar to go straight to the switcher (§11: 约 0.42 秒).
    static let holdToSwitcherDuration: TimeInterval = 0.42
    /// Press-and-hold movement allowance: the finger must stay within
    /// 14pt while holding (demo §8.2).
    static let holdMaxMovement: CGFloat = 14
    /// Stillness after a swipe-up that means "hold": 60 ms (demo §8.2).
    static let swipeHoldStillDuration: TimeInterval = 0.06
    /// Swipe-up distance that counts as "holding the shrunken window".
    static let swipeHoldMinUpward: CGFloat = 30
    /// Full shrink at half the screen height; smallest window scale.
    static let minWindowScale: CGFloat = 0.78
    /// The switcher window: a release inside this upward range (and
    /// not flicking down) opens the switcher (demo §8.2).
    static let switcherMinUpward: CGFloat = 32
    /// A release past this fraction of the screen height goes to the
    /// desktop (demo §8.2: up > 22% H).
    static let goDesktopMinUpwardFraction: CGFloat = 0.22
    /// …or a fast upward flick that is still above 26pt (demo §8.2).
    static let goDesktopFlickMinUpward: CGFloat = 26

    /// Follow progress p (0 at rest, 1 at full shrink): the front
    /// window's scale is 1 − p·0.22, and the Dock / desktop follow
    /// formulas read p (demo §8.1 / §8.3).
    @Published private(set) var followProgress: CGFloat = 0
    /// The front window's vertical drift while following
    /// (−up·0.1 + down·0.16, demo §8.3).
    @Published private(set) var windowOffsetY: CGFloat = 0
    /// The front window's corner radius in 3 discrete steps
    /// (0 / 22 / 38 pt, demo §8.3).
    @Published private(set) var windowCornerRadius: CGFloat = 0
    /// Window scale driven by the gesture (transform only, §14).
    /// 1.0 at rest; shrinks towards 0.78 at full follow.
    var windowScale: CGFloat { 1 - followProgress * 0.22 }
    @Published private(set) var isGestureActive = false
    /// Action the caller must take, once. The caller handles it via
    /// .onChange(of:) and clears it by setting it back to nil.
    @Published var pendingAction: LCSealBoxHomeBarAction?

    private let sampler = LCFrameSampler()
    private let velocityTracker = LCVelocityTracker()
    private var gestureStartTime: CFTimeInterval = 0
    private var lastMoveTime: CFTimeInterval = 0
    private var lastRecordedTranslation = CGPoint.zero
    /// Time of the last light tap on the bar, for the manual
    /// double-tap check (demo §8.3: two taps < 380 ms apart).
    private var lastBarTapTime: CFTimeInterval = 0
    private var switcherFired = false
    /// Set while a gesture was consumed by the switcher, so the same
    /// finger's continued movement cannot start a second gesture.
    private var gestureConsumed = false
    /// The screen height at gesture start (the follow formulas are
    /// fractions of it: full shrink at H·0.5, switcher window to H·0.65).
    private var screenHeight: CGFloat = 800

    // MARK: Gesture lifecycle (called from the view's DragGesture)

    func beginGesture() {
        guard !isGestureActive, !gestureConsumed else {
            return
        }
        isGestureActive = true
        switcherFired = false
        gestureStartTime = CACurrentMediaTime()
        lastMoveTime = gestureStartTime
        lastRecordedTranslation = .zero
        screenHeight = UIScreen.main.bounds.height
        velocityTracker.reset()
        velocityTracker.record(.zero)
        sampler.record(.zero)
        sampler.onFrame = { [weak self] point in
            self?.applyFrame(point)
        }
        sampler.start()
    }

    func recordTranslation(_ translation: CGPoint) {
        guard isGestureActive else {
            return
        }
        let now = CACurrentMediaTime()
        velocityTracker.record(translation, at: now)
        if abs(translation.x - lastRecordedTranslation.x) > 2
            || abs(translation.y - lastRecordedTranslation.y) > 2 {
            lastMoveTime = now
            lastRecordedTranslation = translation
        }
        sampler.record(translation)
    }

    func endGesture(translation: CGPoint) {
        guard isGestureActive else {
            gestureConsumed = false
            return
        }
        sampler.stop()
        isGestureActive = false
        gestureConsumed = false
        if switcherFired {
            // The switcher is already opening; the window just springs back.
            restoreWindow()
            return
        }
        // Release precedence (demo §8.3, flick listed first): a fast
        // flick or a far swipe goes to the desktop; only a slow
        // release inside the middle zone opens the switcher. The
        // mid-gesture pause check (applyFrame) already opens the
        // switcher while dragging, so a slow drag that pauses never
        // reaches this release check.
        let up = -translation.y
        let vy = velocityTracker.velocity.dy
        if up > screenHeight * Self.goDesktopMinUpwardFraction
            || (vy < -0.55 && up > Self.goDesktopFlickMinUpward) {
            restoreWindow()
            requestAction(.goDesktop)
        } else if up >= Self.switcherMinUpward, up <= screenHeight * 0.65, vy > -0.85 {
            restoreWindow()
            requestAction(.openSwitcher)
        } else {
            // Slow short drag released: spring back, no action.
            restoreWindow()
        }
    }

    /// System interruption (call, backgrounding) or an explicit cancel:
    /// the window falls back to exactly its pre-gesture state (§11).
    func cancelGesture() {
        sampler.stop()
        velocityTracker.reset()
        isGestureActive = false
        gestureConsumed = false
        switcherFired = false
        restoreWindow()
    }

    /// Same as cancelGesture, for scenePhase / disappear hooks.
    func resetToPreGesture() {
        cancelGesture()
    }

    /// Double-tap on the bar: straight to the switcher (§11).
    func requestOpenSwitcher() {
        requestAction(.openSwitcher)
    }

    /// A light tap on the bar (from the view's TapGesture): two taps
    /// < 380 ms apart open the switcher (demo §8.3). A single tap does
    /// nothing except press feedback. Manual timing (not the system's
    /// double-tap recogniser) so the 380 ms matches the demo exactly.
    func recordBarTap() {
        let now = CACurrentMediaTime()
        defer { lastBarTapTime = now }
        guard now - lastBarTapTime < Self.doubleTapMaxInterval else {
            return
        }
        lastBarTapTime = 0
        requestAction(.openSwitcher)
    }

    /// Press-and-hold fired (from the strip's LongPressGesture, which
    /// runs even when the finger never moves far enough to start the
    /// drag): straight to the switcher (demo §8.2). Guarded so a
    /// second fire (from the drag's own hold check) is a no-op.
    func pressHoldFired() {
        guard !switcherFired else { return }
        fireSwitcher()
    }

    // MARK: Frame application (§14: one style write per frame)

    private func applyFrame(_ translation: CGPoint) {
        guard isGestureActive else {
            return
        }
        // Swipe up: the whole window shrinks proportionally (not a move).
        // Swipe down: no stretch, scale stays 1, but the window drifts
        // down slightly (demo §8.3: offsetY = −up·0.1 + down·0.16).
        // The corner radius steps 0 / 22 / 38 pt at p < 0.04 / < 0.5 / ≥ 0.5.
        let up = max(0, -translation.y)
        let down = max(0, translation.y)
        let progress = min(1, up / (screenHeight * 0.5))
        followProgress = progress
        windowOffsetY = -up * 0.1 + down * 0.16
        windowCornerRadius = progress < 0.04 ? 0 : progress < 0.5 ? 22 : 38

        guard !switcherFired else {
            return
        }
        let now = CACurrentMediaTime()
        let moved = hypot(translation.x, translation.y)
        if moved < Self.holdMaxMovement, now - gestureStartTime >= Self.holdToSwitcherDuration {
            // Press-and-hold ~0.42 s: straight to the switcher.
            fireSwitcher()
        } else if up > Self.swipeHoldMinUpward, up < screenHeight * 0.62 {
            if now - lastMoveTime >= Self.swipeHoldStillDuration {
                // Swiped up and held still ≥ 60 ms: enter the switcher
                // on the same stream.
                fireSwitcher()
            } else if abs(velocityTracker.velocity.dy) < 0.15, now - gestureStartTime >= Self.swipeHoldStillDuration {
                // …or the finger is barely moving: same trigger.
                fireSwitcher()
            }
        }
    }

    private func fireSwitcher() {
        switcherFired = true
        gestureConsumed = true
        sampler.stop()
        isGestureActive = false
        restoreWindow()
        requestAction(.openSwitcher)
    }

    private func requestAction(_ action: LCSealBoxHomeBarAction) {
        // Never overwrite an action the caller has not handled yet.
        guard pendingAction == nil else {
            return
        }
        pendingAction = action
    }

    private func restoreWindow() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            followProgress = 0
            windowOffsetY = 0
            windowCornerRadius = 0
        }
    }
}

// MARK: - Home indicator view (the bar itself)

/// SealBox's virtual home bar (demo §8).
///
/// Two modes, chosen by the caller:
/// - App open (`isAppOpen == true`): the glass capsule is visible —
///   13pt lock icon + 96×5 white line + "SealBox" 10pt bold tag —
///   bottom 118pt, centred above the Dock. The hit area is the capsule
///   expanded 44pt left/right, 28pt up, 22pt down. The caller only
///   mounts this mode while locked (the capsule never shows unlocked).
/// - Desktop (`isAppOpen == false`): no visible bar at all — only an
///   invisible centred strip, 34pt tall, width max(280pt, 76% of
///   screen width), sitting directly above the Dock (see the file
///   header for why it is not at the screen bottom).
/// In both modes the gestures exist ONLY while locked; unlocked, the
/// view does not hit-test at all, so Dock taps and the real system's
/// Home gesture are untouched.
struct LCSealBoxHomeIndicatorView: View {
    @ObservedObject var state: LCSealBoxHomeBarState
    var isLocked: Bool
    var isAppOpen: Bool = false

    /// Measured capsule size, for sizing the expanded hit area.
    @State private var capsuleSize: CGSize = CGSize(width: 200, height: 31)
    /// Press feedback (demo §8.2): capsule scales 1.07 and brightens
    /// ×1.3 while pressed.
    @State private var isPressed = false
    /// Entry animation (demo §8.2: vbar-in 0.5 s spring-pop from
    /// translateY(14) scale(.92), opacity 0).
    @State private var entered = false

    var body: some View {
        Group {
            if isAppOpen {
                virtualBar
            } else {
                desktopStrip
            }
        }
    }

    // MARK: Virtual bar (app open, locked)

    private var virtualBar: some View {
        capsule
            .scaleEffect(barScale)
            .brightness(isPressed ? 0.3 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
            .opacity(entered ? 1 : 0)
            .offset(y: entered ? 0 : 14)
            .overlay {
                // Expanded hit area (demo §8.3): capsule +44 left/right,
                // +28 up, +22 down. An overlay does not change layout,
                // so the capsule's bottom stays exactly 118pt above the
                // screen bottom (the .padding below). Its bottom edge
                // (118 − 22 = 96pt up) never enters the bottom-36pt
                // system gesture zone.
                Color.clear
                    .frame(
                        width: capsuleSize.width + 2 * LCSealBoxHomeBarState.virtualBarHitExpandHorizontal,
                        height: capsuleSize.height + LCSealBoxHomeBarState.virtualBarHitExpandTop + LCSealBoxHomeBarState.virtualBarHitExpandBottom
                    )
                    .contentShape(Rectangle())
                    .allowsHitTesting(isLocked)
                    .gesture(dragGesture, including: isLocked ? .all : .none)
                    .simultaneousGesture(pressTracker, including: isLocked ? .all : .none)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: LCSealBoxHomeBarState.holdToSwitcherDuration, maximumDistance: LCSealBoxHomeBarState.holdMaxMovement)
                            .onEnded { _ in
                                if isLocked {
                                    state.pressHoldFired()
                                }
                            },
                        including: isLocked ? .all : .none
                    )
                    .onTapGesture {
                        if isLocked {
                            state.recordBarTap()
                        }
                    }
            }
            .padding(.bottom, LCSealBoxHomeBarState.virtualBarBottomOffset)
            .onAppear {
                entered = false
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    entered = true
                }
            }
            .onDisappear {
                entered = false
                isPressed = false
            }
    }

    /// Entry scale (0.92 → 1) times press scale (1.07 while pressed).
    private var barScale: CGFloat {
        let entryScale: CGFloat = entered ? 1 : 0.92
        return entryScale * (isPressed ? 1.07 : 1)
    }

    /// The capsule itself: glass, 13pt lock icon + 96×5 white line
    /// (with a 3pt translucent ring) + "SealBox" 10pt bold tag
    /// (demo §8.2). Never hit-tests on its own — the expanded hit
    /// area above owns the gestures.
    private var capsule: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Capsule()
                .fill(.white)
                .frame(width: 96, height: 5)
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(0.3), lineWidth: 3)
                        .padding(-3)
                }
            Text("SealBox")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 16)
        .background(.ultraThinMaterial, in: Capsule())
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { capsuleSize = proxy.size }
                    .onChange(of: proxy.size) { size in
                        capsuleSize = size
                    }
            }
        )
        .allowsHitTesting(false)
    }

    // MARK: Desktop strip (invisible hit area only)

    private var desktopStrip: some View {
        Color.clear
            .frame(
                width: max(
                    LCSealBoxHomeBarState.desktopStripMinWidth,
                    UIScreen.main.bounds.width * LCSealBoxHomeBarState.desktopStripWidthFraction
                ),
                height: LCSealBoxHomeBarState.desktopStripHeight
            )
            .contentShape(Rectangle())
            .allowsHitTesting(isLocked)
            .gesture(dragGesture, including: isLocked ? .all : .none)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: LCSealBoxHomeBarState.holdToSwitcherDuration, maximumDistance: LCSealBoxHomeBarState.holdMaxMovement)
                    .onEnded { _ in
                        if isLocked {
                            state.pressHoldFired()
                        }
                    },
                including: isLocked ? .all : .none
            )
            .onTapGesture {
                if isLocked {
                    state.recordBarTap()
                }
            }
    }

    // MARK: Shared gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if !state.isGestureActive {
                    state.beginGesture()
                }
                state.recordTranslation(CGPoint(x: value.translation.width, y: value.translation.height))
            }
            .onEnded { value in
                isPressed = false
                state.endGesture(
                    translation: CGPoint(x: value.translation.width, y: value.translation.height)
                )
            }
    }

    /// Press tracking (demo §8.2): a zero-distance drag that only
    /// records press state. Simultaneous with the real drag gesture,
    /// so it never steals the gesture — it only drives the 1.07× /
    /// brightness press feedback.
    private var pressTracker: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                isPressed = true
            }
            .onEnded { _ in
                isPressed = false
            }
    }
}

// MARK: - Floating lock button (app open only)

/// Lock button (demo §8.1): 40×40 circle, shown only while an app is
/// open — never on the desktop. Locked vs unlocked is shown ONLY by
/// the closed/open lock icon — no glow, no colour change (§11). The
/// caller positions it (right 14, bottom 118).
struct LCSealBoxLockButton: View {
    @ObservedObject var lockStore: LCSealBoxLockStore

    var body: some View {
        Button {
            lockStore.isLocked.toggle()
        } label: {
            Image(systemName: lockStore.isLocked ? "lock.fill" : "lock.open")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(lockStore.isLocked ? "已锁定横杠" : "未锁定横杠")
    }
}
