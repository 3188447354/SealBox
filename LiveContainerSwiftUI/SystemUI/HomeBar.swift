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
//  - 0.0.8: the switcher is gone with the multitask window mode —
//    hold / double-tap / swipe-up-pause on the bar do nothing now.
//  - Animation spring 0.35 / 0.85.
//  - Hit zone: the bar is max(280 px, 76% of screen width); its bottom
//    edge stays within 36 pt of the screen bottom.
//
//  The bar is a view, not a global gesture: the parent mounts it as an
//  overlay on the page it belongs to and binds `windowScale`, which the
//  parent applies to that page's content. The gesture state lives in
//  HomeBarGestureModel (a class) so the drag callbacks can mutate the
//  scale binding without copying the View struct.

import Foundation
import SwiftUI

struct HomeBarView: View {
    var onReturnToDesktop: () -> Void
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

// MARK: - Gesture state machine (class: owned by the drag callbacks)

final class HomeBarGestureModel: ObservableObject {
    var onReturnToDesktop: (() -> Void)?
    var windowScale: Binding<CGFloat>?

    func cancel() {
        setWindowScale(1.0)
    }

    func dragChanged(_ value: DragGesture.Value) {
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
        let up = -value.translation.height

        // Fast swipe, or swipe > 140 pt: straight back.
        let fastUp = value.predictedEndTranslation.height < -140
        if up >= 32 || up > 140 || fastUp {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                setWindowScale(1.0)
            }
            onReturnToDesktop?()
            return
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
}
