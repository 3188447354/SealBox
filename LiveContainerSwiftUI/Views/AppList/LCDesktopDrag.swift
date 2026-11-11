//
//  LCDesktopDrag.swift
//  LiveContainerSwiftUI
//
//  Desktop grid v1: drag & drop for the desktop grid, cross-page drag and
//  Dock drag in / out. Pure SwiftUI onDrag / onDrop only; no third-party
//  drag library.
//
//  How the gestures are kept apart (see DESKTOP_GRID_V1.md for the full
//  discussion; device verification still needed):
//  - Tap to launch is disabled while isEditing (the cell's onTapGesture
//    returns early), so a tap can never launch an app by accident in
//    edit mode.
//  - Long-press (0.5 s) enters edit mode. onDrag on iOS itself needs a
//    press-and-hold before the drag starts, so in normal mode a long
//    press first enters edit mode and the same touch can continue into a
//    drag; a quick horizontal swipe never enters edit mode and goes to
//    the pager's swipe instead.
//  - The drag payload is the icon's id string (UTType.text). The dragged
//    id is also kept in LCDesktopDragState so DropDelegates can act on it
//    synchronously; DropInfo item providers are async and cannot be
//    awaited inside dropEntered / performDrop.
//  - Cross-page drag: while a drag is active, invisible 28pt edge zones
//    appear at the left / right screen edges. Hovering over one starts a
//    0.7 s timer that flips one page (and re-arms while still hovering,
//    so holding at the edge keeps flipping). Dropping on a page's blank
//    area lands the icon at the end of that page; dropping on the last
//    page's blank area is allowed.
//  - Dock drag in: dropping on the Dock inserts at the front; if the
//    Dock is full (4), the last Dock icon is evicted back to the grid
//    (never lost, never deleted). Drag out: the Dock leaves an empty
//    slot and does NOT auto-fill; manual order wins from then on.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared drag state

final class LCDesktopDragState: ObservableObject {
    /// Id of the icon currently being dragged, if any.
    @Published var draggedID: String?
    /// Id of the cell currently hovered as a drop target (empty-slot hint).
    @Published var dropTargetID: String?
    /// True while the dragged icon hovers over the Dock.
    @Published var isOverDock = false

    var isDragging: Bool { draggedID != nil }

    /// Set by the view: flipping one page in `direction`.
    var flipPageAction: ((LCDesktopEdgeDirection) -> Void)?

    private var edgeFlipTimer: Timer?

    func beginDrag(id: String) {
        draggedID = id
        dropTargetID = nil
        isOverDock = false
    }

    func endDrag() {
        draggedID = nil
        dropTargetID = nil
        isOverDock = false
        cancelEdgeFlipTimer()
    }

    /// Start the edge auto-flip timer. Fires once after 0.5 s, then
    /// re-arms itself while the drag still hovers the edge. Was 0.7 s:
    /// hovering at the edge felt laggy next to the iPhone home screen,
    /// which flips after about half a second.
    func beginEdgeFlip(direction: LCDesktopEdgeDirection) {
        cancelEdgeFlipTimer()
        edgeFlipTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self, self.draggedID != nil else {
                return
            }
            self.flipPageAction?(direction)
            self.beginEdgeFlip(direction: direction)
        }
    }

    func cancelEdgeFlipTimer() {
        edgeFlipTimer?.invalidate()
        edgeFlipTimer = nil
    }
}

enum LCDesktopEdgeDirection {
    case previous
    case next
}

// MARK: - Drop delegates

/// Drop on a grid cell: the dragged icon is inserted at this cell's
/// position, the displaced icons make room, and the cell shows an
/// empty-slot hint while hovered.
struct LCDesktopCellDropDelegate: DropDelegate {
    let targetID: String
    let dragState: LCDesktopDragState
    /// Move the dragged icon to just before `targetID`.
    let onMove: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard dragState.draggedID != nil else {
            return
        }
        dragState.dropTargetID = targetID
    }

    func dropExited(info: DropInfo) {
        if dragState.dropTargetID == targetID {
            dragState.dropTargetID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID = dragState.draggedID, draggedID != targetID else {
            return false
        }
        dragState.dropTargetID = nil
        onMove(draggedID, targetID)
        return true
    }
}

/// Drop on a page's blank area (or the grid background): the dragged icon
/// lands at the end of that page.
struct LCDesktopPageDropDelegate: DropDelegate {
    let page: Int
    let dragState: LCDesktopDragState
    /// Move the dragged icon to the end of `page`.
    let onMoveToPageEnd: (String, Int) -> Void

    func dropEntered(info: DropInfo) {
        dragState.dropTargetID = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedID = dragState.draggedID else {
            return false
        }
        onMoveToPageEnd(draggedID, page)
        return true
    }
}

/// Hover zone at the left / right screen edge. Not a drop target itself:
/// hovering flips pages while the drag is held at the edge.
struct LCDesktopEdgeDropDelegate: DropDelegate {
    let direction: LCDesktopEdgeDirection
    let dragState: LCDesktopDragState

    func dropEntered(info: DropInfo) {
        guard dragState.draggedID != nil else {
            return
        }
        dragState.beginEdgeFlip(direction: direction)
    }

    func dropExited(info: DropInfo) {
        dragState.cancelEdgeFlipTimer()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

/// Drop on the Dock: highlight the Dock while hovering; on drop the caller
/// inserts the icon (evicting the last Dock icon if full). The dragged id
/// is supplied by the Dock view from the shared drag state (see
/// LCDesktopDockView); DropInfo providers are async and cannot be awaited
/// inside performDrop, so the delegate only signals enter / exit / drop.
struct LCDesktopDockDropDelegate: DropDelegate {
    let onDragEntered: () -> Void
    let onDragExited: () -> Void
    let onDrop: (String) -> Void

    func dropEntered(info: DropInfo) {
        onDragEntered()
    }

    func dropExited(info: DropInfo) {
        onDragExited()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        onDrop("")
        return true
    }
}
