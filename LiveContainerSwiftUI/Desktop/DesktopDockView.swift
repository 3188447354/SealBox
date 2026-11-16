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
//    below), not a SwiftUI Material. 0.0.5: transparent, not
//    frosted — MJ on device still saw frost on 0.0.4's .regular
//    glass. On iOS 26+ the effect is UIGlassEffect (.clear); below
//    iOS 26 there is no effect at all (nil), so the wallpaper shows
//    straight through and the icons float on it directly.
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
/// 0.0.5: transparent, not frosted — MJ on device (iPhone 14 Pro
/// Max, iOS 27) still saw frost on 0.0.4's .regular glass.
/// iOS 26+: UIGlassEffect (.clear) — transparent Liquid Glass, the
/// wallpaper shows straight through. iOS 15-25: no effect at all
/// (UIVisualEffectView with a nil effect) — fully transparent, the
/// icons float straight on the wallpaper; no blur, no fill, no tint.
/// The corner radius is applied to the effect view's own layer
/// (continuous curve) so the glass itself is clipped round — no
/// SwiftUI shape, no stroke.
private struct NativeDockBackground: UIViewRepresentable {
    static let cornerRadius: CGFloat = 30

    func makeUIView(context: Context) -> UIVisualEffectView {
        let effect: UIVisualEffect?
        if #available(iOS 26.0, *) {
            effect = UIGlassEffect(style: .clear)
        } else {
            effect = nil
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
    /// Normal-mode long-press release without a drag: the desktop
    /// shows the custom menu for this icon (item 7).
    var onMenuRequest: ((LCDesktopIcon, Int) -> Void)? = nil
    /// Edit-mode drag-out: the desktop owns the drop resolution.
    var onDragBegin: ((LCDesktopIcon, Int) -> Void)? = nil
    var onDragUpdate: ((CGSize) -> Void)? = nil
    var onDragEnd: (() -> Void)? = nil
    /// Slot lifted by a normal-mode long-press (item 7): it scales
    /// up in place until the finger moves (drag) or lifts (menu).
    @State private var liftedSlot: Int?

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
        .scaleEffect(liftedSlot == slot ? LCDesktopDragState.dragLiftScale : 1.0)
        .shadow(color: liftedSlot == slot ? .black.opacity(0.35) : .clear, radius: liftedSlot == slot ? 12 : 0, x: 0, y: 8)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: DockSlotFrameKey.self,
                    value: [slot: geometry.frame(in: .named("desktop"))]
                )
            }
        )
        if isEditing {
            // 0.0.4: high-priority so the Dock drag wins over the
            // desktop's own gestures (pull-down search / control
            // centre) — a drag starting on a Dock icon must move the
            // icon, not pull the desktop down.
            // 0.0.6: no coordinateSpace: — values arrive in the slot's
            // local space (see desktopPoint); the old .named("desktop")
            // was silently ignored, so the ghost did not follow the
            // finger. Converted with the slot frame, as in the grid.
            button.highPriorityGesture(
                DragGesture(minimumDistance: LCDesktopDragState.dragStartDistance)
                    .onChanged { value in
                        if dragState.draggedID == nil {
                            onDragBegin?(icon, slot)
                            dragState.beginDrag(id: icon.id, at: desktopPoint(value.startLocation, dockSlot: slot))
                        }
                        dragState.updateDrag(translation: value.translation, location: desktopPoint(value.location, dockSlot: slot))
                        onDragUpdate?(value.translation)
                    }
                    .onEnded { _ in
                        onDragEnd?()
                    }
            )
        } else {
            // 0.0.5: normal-mode long-press drag (item 7), same as
            // the grid: lift, drag, or menu on release. The old
            // onLongPressGesture (enter edit mode) is gone — edit
            // mode is still one tap away in the menu ("编辑主屏幕").
            // High-priority so the Dock drag wins over the desktop's
            // own gestures, as in edit mode above.
            button.highPriorityGesture(dockLongPressDragGesture(for: icon, slot: slot))
        }
    }

    /// Convert a drag-gesture point from the attaching slot's local
    /// space to "desktop" space (0.0.6) — same reason as the grid's
    /// desktopPoint in DesktopView: the coordinateSpace: parameter is
    /// not honoured for these gestures, so values arrive in the slot's
    /// local space and must be offset by the slot's frame origin
    /// (reported in desktop space by the same GeometryReader).
    private func desktopPoint(_ local: CGPoint, dockSlot: Int) -> CGPoint {
        if let frame = dragState.dockSlotFrames[dockSlot] {
            return CGPoint(x: frame.minX + local.x, y: frame.minY + local.y)
        }
        return local
    }

    /// Normal-mode long-press drag for a Dock icon (item 7, iOS
    /// behaviour): press 0.45 s and the icon lifts in place; move
    /// and it drags out of the Dock (the same finger, no lift);
    /// release without moving and the menu opens. A quick tap still
    /// opens the app (the Button owns it).
    private func dockLongPressDragGesture(for icon: LCDesktopIcon, slot: Int) -> some Gesture {
        // 0.0.6: no coordinateSpace: — see desktopPoint above; the old
        // .named("desktop") was silently ignored.
        LongPressGesture(minimumDuration: LCDesktopDragState.longPressDuration)
            .sequenced(before: DragGesture(minimumDistance: LCDesktopDragState.dragStartDistance))
            .onChanged { value in
                switch value {
                case .first(let pressed):
                    if pressed { liftedSlot = slot }
                case .second(true, let drag):
                    guard let drag else { return }
                    if dragState.draggedID == nil {
                        onDragBegin?(icon, slot)
                        dragState.beginDrag(id: icon.id, at: desktopPoint(drag.startLocation, dockSlot: slot))
                        liftedSlot = nil
                    }
                    dragState.updateDrag(translation: drag.translation, location: desktopPoint(drag.location, dockSlot: slot))
                    onDragUpdate?(drag.translation)
                default:
                    break
                }
            }
            .onEnded { value in
                liftedSlot = nil
                switch value {
                case .second(true, _):
                    if dragState.draggedID != nil {
                        onDragEnd?()
                    } else {
                        onMenuRequest?(icon, slot)
                    }
                default:
                    break
                }
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
