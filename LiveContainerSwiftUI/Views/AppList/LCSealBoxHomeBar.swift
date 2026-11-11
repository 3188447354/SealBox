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
    /// Stillness after a swipe-up that means "hold" (§11: 上滑并停顿进入切换器).
    static let swipeHoldStillDuration: TimeInterval = 0.35
    /// Swipe-up distance that counts as "holding the shrunken window".
    static let swipeHoldMinUpward: CGFloat = 60
    /// Full shrink at 240pt of upward drag; smallest window scale.
    static let fullShrinkUpward: CGFloat = 240
    static let minWindowScale: CGFloat = 0.85
    /// Release past this upward distance goes to the desktop.
    static let goDesktopMinUpward: CGFloat = 140
    /// …or a fast flick whose predicted end passes this distance.
    static let goDesktopMinPredictedUpward: CGFloat = 200

    /// Window scale driven by the gesture (transform only, §14).
    /// 1.0 at rest; shrinks towards minWindowScale while swiping up.
    @Published private(set) var windowScale: CGFloat = 1.0
    @Published private(set) var isGestureActive = false
    /// Action the caller must take, once. The caller handles it via
    /// .onChange(of:) and clears it by setting it back to nil.
    @Published var pendingAction: LCSealBoxHomeBarAction?

    private let sampler = LCFrameSampler()
    private var gestureStartTime: CFTimeInterval = 0
    private var lastMoveTime: CFTimeInterval = 0
    private var lastRecordedTranslation = CGPoint.zero
    private var switcherFired = false
    /// Set while a gesture was consumed by the switcher, so the same
    /// finger's continued movement cannot start a second gesture.
    private var gestureConsumed = false

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
        if abs(translation.x - lastRecordedTranslation.x) > 2
            || abs(translation.y - lastRecordedTranslation.y) > 2 {
            lastMoveTime = now
            lastRecordedTranslation = translation
        }
        sampler.record(translation)
    }

    func endGesture(translation: CGPoint, predictedEndTranslation: CGPoint) {
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
        let up = -translation.y
        let predictedUp = -predictedEndTranslation.y
        if up > Self.goDesktopMinUpward || predictedUp > Self.goDesktopMinPredictedUpward {
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

    // MARK: Frame application (§14: one style write per frame)

    private func applyFrame(_ translation: CGPoint) {
        guard isGestureActive else {
            return
        }
        // Swipe up: the whole window shrinks proportionally (not a move).
        // Swipe down: no stretch, scale stays 1.
        let up = max(0, -translation.y)
        let progress = min(1, up / Self.fullShrinkUpward)
        windowScale = 1 - (1 - Self.minWindowScale) * progress

        guard !switcherFired else {
            return
        }
        let now = CACurrentMediaTime()
        let moved = hypot(translation.x, translation.y)
        if moved < 12, now - gestureStartTime >= Self.holdToSwitcherDuration {
            // Press-and-hold ~0.42 s: straight to the switcher.
            fireSwitcher()
        } else if up > Self.swipeHoldMinUpward, now - lastMoveTime >= Self.swipeHoldStillDuration {
            // Swiped up and held still: enter the switcher on the same stream.
            fireSwitcher()
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
            windowScale = 1.0
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
                    translation: CGPoint(x: value.translation.width, y: value.translation.height),
                    predictedEndTranslation: CGPoint(x: value.predictedEndTranslation.width, y: value.predictedEndTranslation.height)
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
