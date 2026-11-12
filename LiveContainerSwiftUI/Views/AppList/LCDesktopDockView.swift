//
//  LCDesktopDockView.swift
//  LiveContainerSwiftUI
//
//  Desktop grid v1: a self-drawn frosted Dock replacing the system Tab Bar
//  on the Apps page. It holds the most-used imported apps (never system
//  apps such as Phone / WeChat / QQ / Messages), at most 4, with no names
//  and no badges. Icons are 56pt; the Dock is fixed at the bottom via
//  safeAreaInset and does not flip with the pages.
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
        // The 76pt height is fixed (56pt icons + 10pt padding each
        // side) so the bar can never collapse to nothing when empty.
        .frame(minHeight: 76)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
    }

    @ViewBuilder
    private func dockIcon(_ icon: LCDesktopIcon, slot: Int) -> some View {
        let isDragged = draggedID == icon.id
        let isDropTarget = dropTargetSlot == slot
        ZStack(alignment: .topLeading) {
            LCDesktopIconTile(icon: icon, darkModeIcon: darkModeIcon, size: 56)
                // The dragged icon's slot is an empty dashed slot
                // (the ghost is the dragged tile); the hovered slot
                // keeps its icon and gets the demo's 2 pt outline.
                .opacity(isDragged ? 0.0 : 1.0)
                .overlay {
                    if isDragged {
                        RoundedRectangle(cornerRadius: 56 * 0.2667)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                            .foregroundStyle(.secondary)
                            .frame(width: 56, height: 56)
                    }
                    if isDropTarget {
                        RoundedRectangle(cornerRadius: 56 * 0.2667)
                            .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                            .padding(-2)
                            .frame(width: 56, height: 56)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: isDragged)
                .animation(.easeInOut(duration: 0.15), value: isDropTarget)
                .onTapGesture {
                    guard !isEditing else {
                        return
                    }
                    onTapIcon(icon)
                }
                .gesture(dragGestureFor(icon))

            if isEditing {
                Button {
                    onDeleteIcon(icon)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.red))
                }
                .offset(x: -7, y: -7)
            }
        }
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
        return RoundedRectangle(cornerRadius: 56 * 0.2667)
            .strokeBorder(
                style: StrokeStyle(lineWidth: isDropTarget ? 2 : 1.5, dash: isDropTarget ? [] : [4, 4])
            )
            .foregroundStyle(isDropTarget ? Color.white.opacity(0.85) : .secondary)
            .frame(width: 56, height: 56)
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
