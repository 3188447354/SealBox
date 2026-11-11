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

import SwiftUI
import UniformTypeIdentifiers

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

    var onTapIcon: (LCDesktopIcon) -> Void
    var onDeleteIcon: (LCDesktopIcon) -> Void
    var onLongPressIcon: () -> Void
    /// Called when a drag starts from a Dock icon (sets the shared drag
    /// state; the DropDelegates read the dragged id from there).
    var onDragStarted: (LCDesktopIcon) -> Void
    /// Called by the Dock's DropDelegate when a drag starts over the Dock.
    var onDragEntered: () -> Void
    var onDragExited: () -> Void
    var onDropOnDock: (String) -> Void

    var body: some View {
        HStack(spacing: 16) {
            ForEach(0..<LCDesktopDockStore.maxDockItems, id: \.self) { slot in
                if slot < dockIcons.count {
                    dockIcon(dockIcons[slot])
                } else {
                    emptySlot
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
        .overlay {
            if isDragOver {
                RoundedRectangle(cornerRadius: 26)
                    .strokeBorder(.blue, lineWidth: 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onDrop(
            of: [.text],
            delegate: LCDesktopDockDropDelegate(
                onDragEntered: onDragEntered,
                onDragExited: onDragExited,
                // The dragged id is read from the view's `draggedID`
                // (kept in the shared drag state): DropInfo providers are
                // async and cannot be awaited inside performDrop.
                onDrop: { _ in
                    if let draggedID {
                        onDropOnDock(draggedID)
                    }
                }
            )
        )
    }

    @ViewBuilder
    private func dockIcon(_ icon: LCDesktopIcon) -> some View {
        ZStack(alignment: .topLeading) {
            iconTile(icon)
                .frame(width: 56, height: 56)
                // Same lift as the grid cells: bigger, shadowed, spring
                // back on release (was opacity 0.6 with no scale and no
                // animation, so the lift snapped).
                .opacity(draggedID == icon.id ? 0.85 : 1.0)
                .scaleEffect(draggedID == icon.id ? 1.12 : 1.0)
                .shadow(color: draggedID == icon.id ? .black.opacity(0.3) : .clear, radius: draggedID == icon.id ? 10 : 0, x: 0, y: draggedID == icon.id ? 6 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: draggedID)
                .onTapGesture {
                    guard !isEditing else {
                        return
                    }
                    onTapIcon(icon)
                }
                .onLongPressGesture(minimumDuration: 0.5) {
                    onLongPressIcon()
                }
                .apply { tile in
                    // Same long-press fix as the grid: onDrag's internal
                    // press recogniser would claim the touch before the
                    // 0.5 s long-press could fire, so Dock drag only
                    // attaches in edit mode. Outside edit mode the
                    // long-press enters edit mode.
                    if isEditing {
                        tile.onDrag {
                            onDragStarted(icon)
                            return NSItemProvider(object: NSString(string: icon.id))
                        }
                    } else {
                        tile
                    }
                }

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
    }

    private var emptySlot: some View {
        RoundedRectangle(cornerRadius: 56 * 0.2667)
            .strokeBorder(
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
            )
            .foregroundStyle(.secondary)
            .frame(width: 56, height: 56)
            .opacity(isEditing || isDragOver ? 1.0 : 0.0)
    }

    @ViewBuilder
    private func iconTile(_ icon: LCDesktopIcon) -> some View {
        switch icon {
        case .app(let model):
            IconImageView(icon: model.appInfo.iconIsDarkIcon(darkModeIcon))
        case .system(let page):
            RoundedRectangle(cornerRadius: 56 * 0.2667)
                .fill(page.tint)
                .overlay {
                    Image(systemName: page.systemImage)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
        }
    }
}
