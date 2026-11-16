//
//  AppSwitcherView.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — app switcher (system UI, implementation #2).
//
//  Research §2.2.4 / §3 step 10. Lists ONLY the guest apps that are
//  currently running (the host-side signal is LCAppModel.isAppRunning);
//  no fake cards, no system-page cards, and nothing is invented when
//  the list is empty. Cards are equal-sized and always centred; the
//  layering rule is absolute: the card on the right always covers the
//  card on the left, zIndex = 100 + index × 4, the focused card is NOT
//  raised — only a card flying out on swipe-up may go to zIndex 1000.
//
//  0.0.5: a card IS the guest app's own live screen (GuestSceneSnapshot
//  — the native scene's window, or the virtual window's live view),
//  near full-screen, with the app name above it. When no picture can
//  be taken (guest still launching, or a window that never rendered)
//  the card falls back to the icon placeholder — never a black
//  rectangle presented as the app.
//
//  Gestures (all values from research §2.2.4):
//  - Horizontal drag follows 1:1, snaps with spring 0.38 / 0.85.
//  - Tap a card: it scales up and opens (0.46 s spring).
//  - Swipe a card up: it flies out (card height × 1.12, 0.38 s spring)
//    and the parent is told to close it.
//  - Tap empty space / swipe down: back to the desktop.
//  - The × on a card is only an accessibility fallback for the swipe.
//
//  Multitask is LIVE since 0.0.4: opening a card asks the parent to
//  launch the app (LCAppModel.runApp returns early for an
//  already-running app — bringExistingMultitaskWindowIfNeeded brings
//  the existing native scene / virtual window forward instead of
//  relaunching), and closing a card removes it from that snapshot.
//  A guest that runs as the host process itself can only be left via
//  the Home Bar return gesture — the switcher does not claim to kill
//  a process it cannot kill.

import Foundation
import SwiftUI

struct AppSwitcherView: View {
    /// Snapshot of the running guest apps, in switcher order.
    let apps: [LCAppModel]
    var onOpen: ((LCAppModel) -> Void)? = nil
    var onClose: ((LCAppModel) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @State private var focusedIndex = 0
    /// Live horizontal drag offset (1:1 follow).
    @State private var dragOffset: CGFloat = 0
    /// Live vertical offset of the whole switcher (swipe-down dismiss).
    @State private var dismissOffset: CGFloat = 0
    /// Live upward offset of the focused card while it is being swiped up.
    @State private var flyOffset: CGFloat = 0
    /// The card currently flying out (temporarily zIndex 1000).
    @State private var flyingOutID: String?
    /// The card currently opening (scales up, others fade).
    @State private var openingID: String?

    private var clampedFocus: Int {
        guard !apps.isEmpty else { return 0 }
        return min(max(focusedIndex, 0), apps.count - 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = SwitcherMetrics(size: geometry.size)
            ZStack {
                // Tap empty space: back to the desktop.
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss?() }

                if apps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "square.stack")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.8))
                        Text("没有正在运行的应用")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Button("返回桌面") { onDismiss?() }
                            .buttonStyle(.bordered)
                            .tint(.white)
                    }
                } else {
                    switcherTrack(metrics: metrics)
                }
            }
            .offset(y: dismissOffset)
            .gesture(switcherDrag(metrics: metrics))
        }
        .ignoresSafeArea()
    }

    // MARK: - Track

    @ViewBuilder
    private func switcherTrack(metrics: SwitcherMetrics) -> some View {
        let step = metrics.cardWidth + metrics.cardSpacing
        HStack(spacing: metrics.cardSpacing) {
            ForEach(Array(apps.enumerated()), id: \.element) { index, app in
                let id = LCDesktopIcon.appID(for: app)
                SwitcherCard(
                    app: app,
                    size: metrics.cardSize,
                    isFocused: index == clampedFocus,
                    isOpening: openingID == id,
                    isFlyingOut: flyingOutID == id,
                    flyOffset: index == clampedFocus ? flyOffset : 0,
                    dimmed: openingID != nil && openingID != id,
                    onTap: { openCard(app) },
                    onCloseTap: { closeCard(app) }
                )
                .zIndex(Double(flyingOutID == id ? 1000 : 100 + index * 4))
            }
        }
        // Centre the focused card: shift the whole track left by
        // focus × step, plus the live drag offset.
        .offset(x: -CGFloat(clampedFocus) * step + dragOffset)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: clampedFocus)
    }

    // MARK: - Gestures

    private func switcherDrag(metrics: SwitcherMetrics) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !apps.isEmpty, openingID == nil, flyingOutID == nil else { return }
                if abs(value.translation.width) >= abs(value.translation.height) {
                    // Horizontal: 1:1 follow.
                    dragOffset = value.translation.width
                    dismissOffset = 0
                    flyOffset = 0
                } else if value.translation.height < 0 {
                    // Upward: the focused card follows the finger.
                    flyOffset = value.translation.height
                    dragOffset = 0
                    dismissOffset = 0
                } else {
                    // Downward: the whole switcher follows, then dismisses.
                    dismissOffset = value.translation.height
                    dragOffset = 0
                    flyOffset = 0
                }
            }
            .onEnded { value in
                guard !apps.isEmpty, openingID == nil, flyingOutID == nil else { return }
                let step = metrics.cardWidth + metrics.cardSpacing
                if abs(value.translation.width) >= abs(value.translation.height) {
                    // Horizontal snap: nearest card, nudged by velocity.
                    let predicted = value.translation.width + value.predictedEndTranslation.width * 0.2
                    let raw = CGFloat(clampedFocus) - predicted / step
                    let target = Int(round(raw))
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                        focusedIndex = min(max(target, 0), apps.count - 1)
                        dragOffset = 0
                    }
                } else if value.translation.height < -80
                            || value.predictedEndTranslation.height < -metrics.cardHeight {
                    // Swipe up far / fast: fly the focused card out.
                    closeCard(apps[clampedFocus])
                } else if value.translation.height > 80 {
                    // Swipe down: back to the desktop.
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                        dismissOffset = 0
                    }
                    onDismiss?()
                } else {
                    // Short drag: spring everything back.
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                        dragOffset = 0
                        dismissOffset = 0
                        flyOffset = 0
                    }
                }
            }
    }

    // MARK: - Actions

    private func openCard(_ app: LCAppModel) {
        let id = LCDesktopIcon.appID(for: app)
        guard openingID == nil, flyingOutID == nil else { return }
        withAnimation(.spring(response: 0.46, dampingFraction: 0.85)) {
            openingID = id
        }
        // The card scales up for 0.46 s; the parent's launch takes over
        // after the first part of the animation so the two do not fight.
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run {
                openingID = nil
                onOpen?(app)
            }
        }
    }

    private func closeCard(_ app: LCAppModel) {
        let id = LCDesktopIcon.appID(for: app)
        guard flyingOutID == nil, openingID == nil else { return }
        flyingOutID = id
        // Fly-out distance = card height × 1.12 (same geometry as the
        // track metrics).
        let cardHeight = SwitcherMetrics(size: UIScreen.main.bounds.size).cardHeight
        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
            flyOffset = -cardHeight * 1.12
        }
        Task {
            try? await Task.sleep(nanoseconds: 380_000_000)
            await MainActor.run {
                flyingOutID = nil
                flyOffset = 0
                dragOffset = 0
                if focusedIndex >= apps.count - 1 {
                    focusedIndex = max(0, apps.count - 2)
                }
                onClose?(app)
            }
        }
    }
}

// MARK: - Geometry (research §2.2.4)

private struct SwitcherMetrics {
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let cardSpacing: CGFloat

    var cardSize: CGSize { CGSize(width: cardWidth, height: cardHeight) }

    init(size: CGSize) {
        // 54 pt clearance top and bottom, 46 pt for the lower chrome,
        // 36 pt for the app-name label above the card. The card keeps
        // the app screen's aspect (0.4615), so the snapshot fills it
        // edge to edge; width is capped at 88% of the screen.
        // 0.0.5: spacing is a small peek of the neighbour (24 pt) —
        // the old width × 0.58 deck overlap belonged to the small
        // placeholder cards, not to near-full-screen ones.
        let height = max(200, size.height - 2 * 54 - 46 - 36)
        let width = min(height * 0.4615, size.width * 0.88)
        self.cardHeight = height
        self.cardWidth = width
        self.cardSpacing = 24
    }
}

// MARK: - One card

private struct SwitcherCard: View {
    let app: LCAppModel
    let size: CGSize
    var isFocused: Bool
    var isOpening: Bool
    var isFlyingOut: Bool
    var flyOffset: CGFloat
    var dimmed: Bool
    var onTap: () -> Void
    var onCloseTap: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // App name above the card, like the real switcher — the
            // snapshot itself carries no label.
            Text(app.displayName)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                // 0.0.5: the guest's own live screen; icon placeholder
                // when no picture can be taken (see GuestSceneSnapshot).
                GuestAppSnapshotView(app: app)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                // × is only an accessibility fallback for the swipe-up
                // gesture; the gesture remains the primary close path.
                Button(action: onCloseTap) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel("关闭")
            }
            .frame(width: size.width, height: size.height)
        }
        .scaleEffect(isOpening ? 1.08 : 1.0)
        .opacity(dimmed ? 0 : 1.0)
        .offset(y: flyOffset)
        .animation(.easeOut(duration: 0.18), value: dimmed)
        .onTapGesture(perform: onTap)
    }
}
