//
//  DesktopDockView.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — the Dock.
//
//  Research §1.5: 4 slots, fixed at the bottom of every page (never
//  follows paging), frosted glass (.ultraThinMaterial, corner radius 30,
//  1pt white stroke at 0.25 opacity, no opaque backing), never collapses
//  when empty (min height 88pt), width min(536pt, 100% − 24pt), bottom
//  margin 12pt, icons 60×60, icon spacing 16, horizontal padding 18,
//  vertical padding 10. Dock icons have no names and no badges. Full
//  Dock: dragging a 5th icon in pushes the last one back to the grid
//  (never drops an app); dragging one out leaves an empty slot —
//  nothing auto-fills. The Dock never moves with the keyboard
//  (.ignoresSafeArea(.keyboard)).

import Foundation
import SwiftUI

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
        HStack(spacing: 16) {
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
        .padding(.vertical, 10)
        .frame(minHeight: 88)
        .frame(maxWidth: min(536, UIScreen.main.bounds.width - 24))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
            button.gesture(
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
