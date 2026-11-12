//
//  LCDesktopDockView.swift
//  LiveContainerSwiftUI
//
//  Desktop grid v1: a self-drawn frosted Dock replacing the system Tab Bar
//  on the Apps page. It holds the most-used imported apps (never system
//  apps such as Phone / WeChat / QQ / Messages), at most 4, with no names
//  and no badges. Icons are 60pt; the Dock is fixed at the bottom via
//  safeAreaInset and does not flip with the pages.
//
//  Geometry (demo §4): fixed, bottom 12pt, min-height 88pt, radius 30pt,
//  blur 22 (SwiftUI material has no numeric blur — .ultraThinMaterial is
//  the native stand-in), width min(536pt, 100% − 24pt), icons 60×60.
//  An empty Dock renders as an empty glass pill (fixed height, never
//  collapsing).
//
//  Dragging (demo §4): Dock icons use the same long-press → drag gesture
//  as the grid (see LCDesktopIconDragGesture in LCDesktopDrag.swift),
//  passed in as `dragGestureFor`. A drop on an occupied Dock slot swaps
//  with that app (it returns to the dragged app's original grid cell);
//  a drop on empty Dock space appends (evicting the last Dock icon if
//  full). Dragging a Dock icon onto another Dock slot is a no-change
//  drop in the demo (it flies back). The dragged Dock icon's slot is
//  drawn as an empty dashed slot while the ghost floats above it.
//  Slot + bar frames are reported for the drag hit-test.
//
//  Edit mode (demo §2.2): Dock icons jiggle identically to grid icons
//  (0.26 s, ±1.5°, per-icon phase) and carry the same 23×23 delete badge.
//  Press feedback (demo §1.2): tile scales to 0.86 within 80 ms.
//

import SwiftUI

/// The Dock. `dockIcons` are the icons currently in the Dock, in Dock
/// order; empty slots are rendered as transparent spacers (dashed outline
/// in edit mode) and are never auto-filled after a manual drag-out.
struct LCDesktopDockView: View {
    let dockIcons: [LCDesktopIcon]
    let isEditing: Bool
    let isDragOver: Bool
    let darkModeIcon: Bool

    /// Dragged icon id while a drag is in progress, if any.
    let draggedID: String?
    /// The Dock slot currently hovered as a drop target (swap), if any.
    let dropTargetSlot: Int?

    var onTapIcon: (LCDesktopIcon) -> Void
    var onDeleteIcon: (LCDesktopIcon) -> Void
    /// The long-press → drag gesture for a Dock icon (built by the
    /// caller, same gesture as the grid cells).
    var dragGestureFor: (LCDesktopIcon) -> AnyGesture<SequenceGesture<LongPressGesture, DragGesture>.Value>

    /// Jiggle phase driver (demo §2.2): flipped on edit-mode entry so
    /// the repeatForever animation oscillates from the `from` angle.
    @State private var jiggling = false
    /// Icon currently pressed (demo §1.2 press feedback, 0.86 in 80 ms).
    @State private var pressingID: String?

    /// Dock icon tile size (demo §4: 60×60).
    static let iconSize: CGFloat = 60

    /// Jiggle duration, per icon (demo §2.2): the icons must not rock in
    /// unison. Derived from the icon id so it is stable per icon:
    /// durations 0.31 / 0.23 / 0.26 s, one variant mirrored.
    private func jiggleDuration(for icon: LCDesktopIcon) -> Double {
        switch abs(icon.id.hashValue) % 3 {
        case 0: return 0.31
        case 1: return 0.23
        default: return 0.26
        }
    }

    /// Jiggle angles (demo §2.2): −1.6°…+1.5°, mirrored (+1.4°…−1.6°)
    /// for every fourth icon.
    private func jiggleAngles(for icon: LCDesktopIcon) -> (from: Double, to: Double) {
        abs(icon.id.hashValue) % 4 == 0 ? (1.4, -1.6) : (-1.6, 1.5)
    }

    var body: some View {
        HStack(spacing: 16) {
            ForEach(0..<LCDesktopDockStore.maxDockItems, id: \.self) { slot in
                if slot < dockIcons.count {
                    dockIcon(dockIcons[slot], slot: slot)
                } else {
                    emptySlot(slot: slot)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        // Original frosted glass: .ultraThinMaterial over the
        // wallpaper, rounded corners, the wallpaper showing through
        // blurred. No opaque colour anywhere (no Color.white / .gray
        // fill): the bar is only visible because the material blurs
        // what is behind it. The hairline white stroke is what makes
        // the EMPTY bar readable against a dark wallpaper — without
        // it, an empty Dock over the dark bottom of the rainy wallpaper
        // is nearly invisible (MJ's 02:56 screenshot: no Dock at all).
        // The 88pt height is fixed (60pt icons + 10pt padding each
        // side, min-height 88 per demo §4) so the bar can never
        // collapse to nothing when empty.
        .frame(minHeight: 88)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30))
        .overlay {
            RoundedRectangle(cornerRadius: 30)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        // Frame reporting for the drag hit-test: the bar rect (empty
        // Dock space = append) in the "desktop" coordinate space.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LCDesktopDockFramePreferenceKey.self,
                    value: LCDesktopDockFrames(bar: proxy.frame(in: .named("desktop")), slots: [:])
                )
            }
        )
        .onChange(of: isEditing) { editing in
            if editing {
                // Start the jiggle from the `from` angle: the angle
                // is `from` while jiggling is false, so flip the phase
                // on the next runloop — the repeatForever animation
                // then oscillates `from` ↔ `to`. Flipping it in this
                // same transaction would interpolate from 0 (the
                // non-editing angle) instead, a one-sided wobble.
                jiggling = false
                DispatchQueue.main.async {
                    jiggling = true
                }
            } else {
                jiggling = false
            }
        }
    }

    @ViewBuilder
    private func dockIcon(_ icon: LCDesktopIcon, slot: Int) -> some View {
        let isDragged = draggedID == icon.id
        let isDropTarget = dropTargetSlot == slot
        let isPressing = pressingID == icon.id
        let angles = jiggleAngles(for: icon)
        ZStack(alignment: .topLeading) {
            LCDesktopIconTile(icon: icon, darkModeIcon: darkModeIcon, size: Self.iconSize)
                // The dragged icon's slot is an empty dashed slot
                // (the ghost is the dragged tile); the hovered slot
                // keeps its icon and gets the demo's 2 pt outline.
                .opacity(isDragged ? 0.0 : 1.0)
                .overlay {
                    if isDragged {
                        RoundedRectangle(cornerRadius: Self.iconSize * 0.2667)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                            .foregroundStyle(.secondary)
                            .frame(width: Self.iconSize, height: Self.iconSize)
                    }
                    if isDropTarget {
                        RoundedRectangle(cornerRadius: Self.iconSize * 0.2667)
                            .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                            .padding(-2)
                            .frame(width: Self.iconSize, height: Self.iconSize)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: isDragged)
                .animation(.easeInOut(duration: 0.15), value: isDropTarget)
                // Press feedback (demo §1.2): 0.86 within 80 ms on
                // press, spring-pop back on release.
                .scaleEffect(isPressing ? 0.86 : 1.0)
                .animation(
                    isPressing ? .easeOut(duration: 0.08) : .spring(response: 0.38, dampingFraction: 0.6),
                    value: isPressing
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // The press clears once the finger moves
                            // > 9 pt, so a page swipe starting on a Dock
                            // icon does not leave it shrunk.
                            if hypot(value.translation.width, value.translation.height) > 9 {
                                if pressingID == icon.id {
                                    pressingID = nil
                                }
                            } else {
                                pressingID = icon.id
                            }
                        }
                        .onEnded { _ in
                            if pressingID == icon.id {
                                pressingID = nil
                            }
                        }
                )
                .onTapGesture {
                    // Edit-mode taps open the app (demo §2.5 / P2-28);
                    // the exit from edit mode happens in
                    // desktopIconTapped. The "−" badge is a sibling
                    // Button, not a descendant of this tile, so
                    // tapping it does not fire this gesture.
                    onTapIcon(icon)
                }
                .gesture(dragGestureFor(icon))

            if isEditing {
                Button {
                    onDeleteIcon(icon)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 23, height: 23)
                        .background(Circle().fill(Color(red: 238 / 255, green: 240 / 255, blue: 245 / 255).opacity(0.96)))
                }
                .offset(x: 2, y: -5)
                // Badge-in (demo §2.2): 0.38 s spring-pop, scale 0 → 1.
                .transition(.scale.combined(with: .opacity))
            }
        }
        // Jiggle (demo §2.2): ±1.5–1.6° with ±0.5 px vertical shift,
        // phase/speed varying per icon so they don't rock in unison.
        .rotationEffect(.degrees(isEditing ? (jiggling ? angles.to : angles.from) : 0))
        .offset(y: isEditing ? (jiggling ? 0.5 : -0.5) : 0)
        .animation(
            isEditing ? .easeInOut(duration: jiggleDuration(for: icon)).repeatForever(autoreverses: true) : .default,
            value: jiggling
        )
        // The delete badge's scale/opacity transition (badge-in) is
        // driven by the edit-mode change.
        .animation(.spring(response: 0.38, dampingFraction: 0.6), value: isEditing)
        // Slot frame for the drag hit-test (positional Dock insert).
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LCDesktopDockFramePreferenceKey.self,
                    value: LCDesktopDockFrames(bar: .zero, slots: [slot: proxy.frame(in: .named("desktop"))])
                )
            }
        )
    }

    private func emptySlot(slot: Int) -> some View {
        let isDropTarget = dropTargetSlot == slot
        return RoundedRectangle(cornerRadius: Self.iconSize * 0.2667)
            .strokeBorder(
                style: StrokeStyle(lineWidth: isDropTarget ? 2 : 1.5, dash: isDropTarget ? [] : [4, 4])
            )
            .foregroundStyle(isDropTarget ? Color.white.opacity(0.85) : .secondary)
            .frame(width: Self.iconSize, height: Self.iconSize)
            .opacity(isEditing || isDragOver || isDropTarget ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.15), value: isDropTarget)
            // Slot frame for the drag hit-test.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: LCDesktopDockFramePreferenceKey.self,
                        value: LCDesktopDockFrames(bar: .zero, slots: [slot: proxy.frame(in: .named("desktop"))])
                    )
                }
            )
    }
}
