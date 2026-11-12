//
//  LCSealBoxHomeBar.swift
//  LiveContainerSwiftUI
//
//  SealBox 应用锁与底部横杠（开发文档 §11 定稿、§14 动画规范）。
//
//  定稿规则：
//  - 只有锁定后才接管横杠手势；未锁定完全不响应、不误触真机。
//  - 接管命中区下沿距屏幕底部 36px 封顶（36pt 高、贴底的命中条）。
//  - 上滑跟手：窗口整体慢慢等比缩小（不是上移）；快滑松手回桌面；
//    上滑并停顿进入应用切换器；按住约 0.42 秒或双击横杠直达切换器。
//  - 进切换器与回桌面是同一条连续手势流，不分段跳变。
//  - 手势被系统打断时，窗口必须回落到进入手势前的完整状态。
//  - 桌面悬浮锁按钮：锁定只靠闭锁图标区分，无发光。
//  - 动画只写 transform / opacity；手势采样与样式写入按帧合并（§14）。
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
    /// Takeover hit zone: 36pt tall, bottom-anchored (§11: 下沿距屏幕底部 36px 封顶).
    static let hitZoneHeight: CGFloat = 36
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
        // Release precedence (demo §8.2): the switcher check FIRST.
        let up = -translation.y
        let vy = velocityTracker.velocity.dy
        if up >= Self.switcherMinUpward, up <= screenHeight * 0.65, vy > -0.85 {
            restoreWindow()
            requestAction(.openSwitcher)
        } else if up > screenHeight * Self.goDesktopMinUpwardFraction
            || (vy < -0.55 && up > Self.goDesktopFlickMinUpward) {
            restoreWindow()
            requestAction(.goDesktop)
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

/// SealBox's own bottom bar: the pill is always drawn (it is the virtual
/// phone's home indicator); the gestures only exist while locked.
/// Unlocked, the strip does not hit-test at all, so Dock taps and the
/// real system's Home gesture are untouched.
struct LCSealBoxHomeIndicatorView: View {
    @ObservedObject var state: LCSealBoxHomeBarState
    var isLocked: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .frame(height: LCSealBoxHomeBarState.hitZoneHeight)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .allowsHitTesting(isLocked)
                .gesture(dragGesture, including: isLocked ? .all : .none)
                // Press-and-hold (demo §8.2): the drag needs 6pt of
                // movement to start, so a finger that presses and
                // never moves would never fire the drag's own hold
                // check. This LongPressGesture runs in parallel and
                // fires at 0.42 s if the finger stays within 14pt —
                // the same trigger, for the stationary press.
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: LCSealBoxHomeBarState.holdToSwitcherDuration, maximumDistance: LCSealBoxHomeBarState.holdMaxMovement)
                        .onEnded { _ in
                            if isLocked {
                                state.pressHoldFired()
                            }
                        },
                    including: isLocked ? .all : .none
                )
                .onTapGesture(count: 2) {
                    if isLocked {
                        state.requestOpenSwitcher()
                    }
                }
            Capsule()
                .fill(Color.white.opacity(0.9))
                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                .frame(width: 134, height: 5)
                .padding(.bottom, 8)
                .allowsHitTesting(false)
        }
        .frame(height: LCSealBoxHomeBarState.hitZoneHeight)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if !state.isGestureActive {
                    state.beginGesture()
                }
                state.recordTranslation(CGPoint(x: value.translation.width, y: value.translation.height))
            }
            .onEnded { value in
                state.endGesture(
                    translation: CGPoint(x: value.translation.width, y: value.translation.height)
                )
            }
    }
}

// MARK: - Floating lock button (desktop only)

/// Floating lock button on the desktop. Locked vs unlocked is shown
/// ONLY by the closed/open lock icon — no glow, no colour change (§11).
/// Hidden while editing (the edit-mode capsules own the corners then).
struct LCSealBoxLockButton: View {
    @ObservedObject var lockStore: LCSealBoxLockStore

    var body: some View {
        Button {
            lockStore.isLocked.toggle()
        } label: {
            Image(systemName: lockStore.isLocked ? "lock.fill" : "lock.open")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(lockStore.isLocked ? "已锁定横杠" : "未锁定横杠")
    }
}
