//
//  HomeBar.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — home bar return gesture (system UI,
//  implementation #2).
//
//  Research §2.2.5. The bar is NOT a floating Home button and is NOT
//  drawn on the desktop: the desktop IS the home screen, so it has no
//  bar. The bar only exists while a guest app or a system page is open,
//  where it owns the way back.
//
//  Thresholds — all locally calibrated values from research §2.2.5,
//  not Apple values:
//  - Swipe up ≥ 32 pt: back to the desktop. A fast swipe, or a swipe
//    > 140 pt, goes back immediately.
//  - While swiping up, the window follows the finger and shrinks, at
//    most to 0.78 (scale = 1 − progress × 0.22).
//  - Open the switcher: hold the bar 0.42 s (moved < 14 pt), or
//    double-tap it (two taps < 380 ms apart), or swipe up and pause
//    0.35 s (still for 60 ms counts as "paused").
//  - Animation spring 0.35 / 0.85.
//  - Hit zone: the bar is max(280 px, 76% of screen width); its bottom
//    edge stays within 36 pt of the screen bottom.
//
//  The bar is a view, not a global gesture: the parent mounts it as an
//  overlay on the page it belongs to and binds `windowScale`, which the
//  parent applies to that page's content. The gesture state lives in
//  HomeBarGestureModel (a class) because the pause-detection timer must
//  mutate live state — a Timer closure capturing the View struct would
//  only ever touch a stale copy.

import Foundation
import SwiftUI

struct HomeBarView: View {
    var onReturnToDesktop: () -> Void
    var onOpenSwitcher: (() -> Void)? = nil
    /// The parent applies this to the page content (the "window" that
    /// shrinks while the finger drags up). 1.0 at rest, down to 0.78.
    var windowScale: Binding<CGFloat>?

    @StateObject private var model = HomeBarGestureModel()
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        // The visible bar is 5 pt tall; the hit area is padded to
        // 44 pt (HIG minimum touch target) and its bottom edge sits
        // 8 pt above the overlay's bottom edge — inside the 36 pt cap.
        let barWidth = max(280, UIScreen.main.bounds.width * 0.76)
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill((colorScheme == .dark ? Color.white : Color.black).opacity(0.35))
            .frame(width: barWidth, height: 5)
            .frame(width: barWidth, height: 44)
            .contentShape(Rectangle())
            .padding(.bottom, 8)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { model.dragChanged($0) }
                    .onEnded { model.dragEnded($0) }
            )
            .onAppear {
                model.onReturnToDesktop = onReturnToDesktop
                model.onOpenSwitcher = onOpenSwitcher
                model.windowScale = windowScale
            }
            .onChange(of: windowScale?.wrappedValue) { _ in
                // Keep the model pointed at the current binding.
                model.windowScale = windowScale
            }
            .onDisappear {
                model.cancel()
                windowScale?.wrappedValue = 1.0
            }
    }
}

// MARK: - Gesture state machine (class: owned by the pause timer)

final class HomeBarGestureModel: ObservableObject {
    var onReturnToDesktop: (() -> Void)?
    var onOpenSwitcher: (() -> Void)?
    var windowScale: Binding<CGFloat>?

    private var pressStart: Date?
    private var pressStartLocation: CGPoint?
    private var lastMove: Date?
    private var lastMoveLocation: CGPoint?
    private var longPressFired = false
    private var pauseFired = false
    private var stillTimer: Timer?
    private var lastTapEnd: Date?
    private var isPressing = false

    func cancel() {
        stillTimer?.invalidate()
        stillTimer = nil
        isPressing = false
        pressStart = nil
        setWindowScale(1.0)
    }

    func dragChanged(_ value: DragGesture.Value) {
        let now = Date()
        if pressStart == nil {
            pressStart = now
            pressStartLocation = value.startLocation
            lastMove = now
            lastMoveLocation = value.location
            isPressing = true
            longPressFired = false
            pauseFired = false
            startStillTimer()
        }
        // Track movement for the hold (< 14 pt) and pause rules.
        if let last = lastMoveLocation,
           hypot(value.location.x - last.x, value.location.y - last.y) > 1 {
            lastMove = now
            lastMoveLocation = value.location
        }
        // Hold 0.42 s with < 14 pt movement: open the switcher.
        if !longPressFired, !pauseFired,
           let start = pressStart, now.timeIntervalSince(start) >= 0.42,
           let origin = pressStartLocation,
           hypot(value.location.x - origin.x, value.location.y - origin.y) < 14 {
            longPressFired = true
            finishPress()
            onOpenSwitcher?()
            return
        }
        // Upward drag: the window follows, shrinking to 0.78.
        let up = -value.translation.height
        if up > 0 {
            let progress = min(1, up / 140)
            setWindowScale(1 - progress * 0.22)
        } else {
            setWindowScale(1.0)
        }
    }

    func dragEnded(_ value: DragGesture.Value) {
        let now = Date()
        let duration = pressStart.map { now.timeIntervalSince($0) } ?? 0
        let moved = pressStartLocation.map {
            hypot(value.location.x - $0.x, value.location.y - $0.y)
        } ?? 0
        let up = -value.translation.height
        let wasLongPress = longPressFired
        let wasPause = pauseFired
        finishPress()

        if wasLongPress || wasPause {
            // Already handled mid-gesture; just restore the scale.
            setWindowScale(1.0)
            return
        }

        // Fast swipe, or swipe > 140 pt: straight back.
        let fastUp = value.predictedEndTranslation.height < -140
        if up >= 32 || up > 140 || fastUp {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                setWindowScale(1.0)
            }
            onReturnToDesktop?()
            return
        }

        // Tap-like press: double-tap (< 380 ms) opens the switcher.
        if moved < 10 && duration < 0.5 {
            if let last = lastTapEnd, now.timeIntervalSince(last) < 0.38 {
                lastTapEnd = nil
                onOpenSwitcher?()
                return
            }
            lastTapEnd = now
        }

        // Short drag: spring the window back.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            setWindowScale(1.0)
        }
    }

    private func setWindowScale(_ scale: CGFloat) {
        // No animation here: the value follows the finger 1:1. The
        // parent animates it back on release (see dragEnded).
        windowScale?.wrappedValue = scale
    }

    private func finishPress() {
        stillTimer?.invalidate()
        stillTimer = nil
        pressStart = nil
        pressStartLocation = nil
        lastMove = nil
        lastMoveLocation = nil
        isPressing = false
    }

    /// While the finger is down and up-swiped, watch for a pause:
    /// still for 60 ms counts as "stopped"; stopped for 0.35 s opens
    /// the switcher. The timer only runs during a press.
    private func startStillTimer() {
        stillTimer?.invalidate()
        stillTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, isPressing, !longPressFired, !pauseFired,
                      let last = lastMove, let start = pressStart else { return }
                let now = Date()
                guard now.timeIntervalSince(start) >= 0.35,
                      now.timeIntervalSince(last) >= 0.06 else { return }
                pauseFired = true
                finishPress()
                setWindowScale(1.0)
                onOpenSwitcher?()
            }
        }
    }
}
