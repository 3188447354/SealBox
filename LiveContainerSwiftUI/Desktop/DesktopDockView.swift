//
//  DesktopDockView.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.4 rebuild — the Dock.
//
//  0.0.4: native, not drawn. The 0.0.3 Dock was SwiftUI-painted
//  (.ultraThinMaterial + a 1pt white stroke) and MJ called it out on
//  device ("Dock 不要画的假的，需要原生的"). The system Dock itself
//  is SpringBoard's — no API embeds it — so this is a 1:1 rebuild
//  with the native components the real Dock is made of:
//  - Container: a real UIVisualEffectView (NativeDockBackground
//    below), not a SwiftUI Material. On iOS 26+ the effect is
//    UIGlassEffect (.regular) — the real Dock on iOS 26/27 IS Liquid
//    Glass (verified: Apple ships the Dock and the Search pill in
//    Liquid Glass; UIGlassEffect follows the user's system
//    Clear/Tinted setting exactly like the real Dock). Below iOS 26
//    it falls back to UIBlurEffect (.systemMaterial) — the pre-26
//    frosted Dock, one grade thicker than ultraThin (ultraThin was
//    the main "fake" cue: the wallpaper bled straight through).
//  - No stroke: the real Dock has no outline at all, only the glass
//    itself. The 1pt white stroke is deleted.
//  - Geometry, measured off a real iOS 26 home-screen screenshot
//    (710x1536, calibrated against the 60pt Dock icons = 105px, so
//    1pt = 1.75px; +/-3pt): platter ~100pt tall (icons 60 + 20 + 20
//    vertical padding — 0.0.3 was 88 and read as a flat slab),
//    side margins ~13pt (kept 12, within 1pt), bottom gap ~14pt
//    from the SCREEN bottom edge (0.0.3 sat 12pt above the safe-area
//    bottom = 46pt off the screen, floating visibly high). Corner
//    radius kept 30 (measured 20-30 range, within tolerance).
//    Icons spread across the platter (spacing 16 -> 30; 0.0.3
//    clustered them in the middle with ~41pt dead margins each
//    side, the real Dock distributes them evenly).
//  - Icons are the real app icons (AppIconImage reads
//    LCAppInfo.iconIsDarkIcon, generated from the bundle's own
//    icon files) — verified, no change.
//  - Behaviour unchanged: 4 slots, tap to launch, edit-mode drag
//    in/out, full Dock pushes the last icon back to the grid,
//    dragging one out leaves an empty slot (nothing auto-fills).
//    The Dock never moves with the keyboard.
//
//  Research §1.5 (0.0.3): 4 slots, fixed at the bottom of every page
//  (never follows paging), never collapses when empty (min height
//  now 100pt), width min(536pt, 100% − 24pt), icons 60×60, no names
//  and no badges.

import Foundation
import SwiftUI

/// The Dock's native background: a real UIVisualEffectView.
///
/// iOS 26+: UIGlassEffect (.regular) — the same Liquid Glass the
/// system Dock is made of, so it tracks the user's Clear/Tinted
/// system setting. iOS 15-25: UIBlurEffect (.systemMaterial), the
/// pre-26 frosted Dock. The corner radius is applied to the effect
/// view's own layer (continuous curve) so the glass itself is
/// clipped round — no SwiftUI shape, no stroke.
private struct NativeDockBackground: UIViewRepresentable {
    static let cornerRadius: CGFloat = 30

    func makeUIView(context: Context) -> UIVisualEffectView {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            effect = UIGlassEffect(style: .regular)
        } else {
            effect = UIBlurEffect(style: .systemMaterial)
        }
        let view = UIVisualEffectView(effect: effect)
        view.backgroundColor = .clear
        view.layer.cornerRadius = Self.cornerRadius
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

struct DesktopDockView: View {
    let dockIcons: [LCDesktopIcon]
    var isEditing: Bool
    var draggedID: String?
    @ObservedObject var dragState: LCDesktopDragState
    var onTap: ((LCDesktopIcon) -> Void)? = nil
    var onLongPress: ((LCDesktopIcon) -> Void)? = nil
    /// Edit-mode drag-out: the desktop owns the drop resolution.
    var onDragBegin: ((LCDesktopIcon, Int) -> Void)? = nil
    var onDragUpdate: ((CGSize) -> Void)? = nil
    var onDragEnd: (() -> Void)? = nil

    static let iconSize: CGFloat = 60

    var body: some View {
        HStack(spacing: 30) {
            ForEach(0..<LCDesktopDockStore.maxDockItems, id: \.self) { slot in
                if slot < dockIcons.count {
                    let icon = dockIcons[slot]
                    dockIcon(icon, slot: slot)
                } else {
                    // Empty slot: keeps the layout and is a drop target.
                    Color.clear
                        .frame(width: Self.iconSize, height: Self.iconSize)
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: DockSlotFrameKey.self,
                                    value: [slot: geometry.frame(in: .named("desktop"))]
                                )
                            }
                        )
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(minHeight: 100)
        .frame(maxWidth: min(536, UIScreen.main.bounds.width - 24))
        .background(NativeDockBackground())
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        // The Dock hugs the screen's bottom edge like the real one
        // (~12pt above it, home indicator in the gap), not the
        // safe-area bottom (which would float it 34pt higher).
        // .container lets it bleed into the bottom safe area; the
        // .keyboard region keeps the old "never moves with the
        // keyboard" behaviour.
        .ignoresSafeArea([.container, .keyboard], edges: .bottom)
    }

    @ViewBuilder
    private func dockIcon(_ icon: LCDesktopIcon, slot: Int) -> some View {
        let button = Button {
            guard !isEditing else { return }
            onTap?(icon)
        } label: {
            ZStack {
                if draggedID == icon.id {
                    RoundedRectangle(cornerRadius: Self.iconSize * 0.2667, style: .continuous)
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: Self.iconSize, height: Self.iconSize)
                } else if case .app(let model) = icon {
                    AppIconImage(app: model, size: Self.iconSize)
                }
            }
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: DockSlotFrameKey.self,
                    value: [slot: geometry.frame(in: .named("desktop"))]
                )
            }
        )
        .onLongPressGesture(minimumDuration: 0.45) {
            onLongPress?(icon)
        }
        if isEditing {
            // 0.0.4: high-priority so the Dock drag wins over the
            // desktop's own gestures (pull-down search / control
            // centre) — a drag starting on a Dock icon must move the
            // icon, not pull the desktop down.
            button.highPriorityGesture(
                DragGesture(minimumDistance: LCDesktopDragState.dragStartDistance)
                    .onChanged { value in
                        if dragState.draggedID == nil {
                            guard let frame = dragState.dockSlotFrames[slot] else { return }
                            onDragBegin?(icon, slot)
                            dragState.beginDrag(id: icon.id, frame: frame, startLocation: value.startLocation)
                        }
                        dragState.updateDrag(translation: value.translation)
                        onDragUpdate?(value.translation)
                    }
                    .onEnded { _ in
                        onDragEnd?()
                    }
            )
        } else {
            button
        }
    }
}

/// Dock slot frames in screen coordinates, reported up to the desktop
/// for the drag hit-test and the launch-zoom anchor.
struct DockSlotFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
