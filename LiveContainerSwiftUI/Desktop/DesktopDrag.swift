//
//  DesktopDrag.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — drag state machine.
//
//  Research §2.2.2 (all values are the shipped fork's calibrated ones,
//  not Apple's — Apple publishes none of them):
//  - long-press 0.45 s, CONSTANT: it must never depend on `isEditing`
//    (the old `isEditing ? 0 : 0.45` swapped the gesture mid-touch and
//    killed both tap and drag). Blank-area long-press uses it; icon drag
//    in edit mode grabs instantly on move > 7pt.
//  - drag starts after > 7pt of movement; the same finger that
//    long-pressed can drag without lifting.
//  - while dragging, the origin cell is a dashed empty slot (2pt dash
//    [5, 4]); the ghost floats above at 1.15× with a shadow; the hovered
//    target keeps its icon + a 2pt white outline (opacity 0.85, outset
//    2pt); fades 0.15 s easeInOut.
//  - landing 0.42 s, no overshoot; dropping on no target flies back to
//    the origin cell over 0.45 s.
//  - cross-page drag: 24pt invisible hot zones at the screen edges,
//    hovering 0.65 s flips one page (the old doc said 0.7 s; the code's
//    0.65 s cooldown wins).
//  - search disables dragging (a drag inside a filtered subset would
//    corrupt the full order) — the search overlay is implementation #2's;
//    until then this flag is always false.
//  - cancelling a drag (lifting on a page dot / count text / any
//    no-target area, or backgrounding) clears the drag state.
//
//  0.0.5: hold-through dragging now works in normal mode too. The
//  old blocker was the SwiftUI contextMenu on the icon, whose own
//  long-press owned the touch. The menu is now a custom overlay
//  (DesktopAppMenuOverlay, in AppContextMenu.swift) shown on a
//  long-press release without a drag, and both grid and Dock icons
//  carry a sequenced LongPress -> Drag gesture: press 0.45 s to lift,
//  move to drag, release without moving for the menu. The ghost /
//  hover / edge-flip machinery below is unchanged.

import Foundation
import SwiftUI

/// Where a drag ends up, resolved from the hit-test frames.
enum DesktopDrop {
    /// Drop on a grid slot: swap with the icon there, or land in the
    /// empty slot (the desktop maps slot -> id).
    case gridSlot(Int)
    /// Drop on a Dock slot: swap with that Dock icon (or append if the
    /// slot is empty — the caller maps an empty slot to `dockAppend`).
    case dockSlot(Int)
    /// Drop on a Dock slot that is empty: append to the Dock (evicting
    /// the last member back to the grid if the Dock is full).
    case dockAppend
    /// No target: fly back to the origin cell.
    case none
}

/// Per-frame finger position, observed ONLY by the drag ghost.
///
/// 0.0.4: this lives outside LCDesktopDragState's @Published set on
/// purpose. The desktop observes that object, so a per-frame write
/// there re-renders every page's grid and the ghost drops frames.
/// The ghost is one icon + one label, so it alone follows the finger
/// at 60 fps. LCDesktopDragState owns the single instance and writes
/// it from updateDrag; the desktop never reads it in its own body —
/// it only passes the reference through to the ghost.
final class LCDesktopDragPosition: ObservableObject {
    @Published var location: CGPoint = .zero
}

final class LCDesktopDragState: ObservableObject {
    /// Long-press duration. Constant 0.45 s — never conditional on edit state.
    static let longPressDuration: TimeInterval = 0.45
    /// Movement that arms a drag (a tap moves less than this).
    static let dragStartDistance: CGFloat = 7
    /// Edge hot-zone width for cross-page drag flips.
    static let edgeFlipZoneWidth: CGFloat = 24
    /// Hover time in an edge zone before the page flips.
    static let edgeFlipCooldown: TimeInterval = 0.65
    /// Landing animation: 0.42 s, no overshoot.
    static let landingDuration: TimeInterval = 0.42
    /// Fly-back to the origin cell: 0.45 s.
    static let flyBackDuration: TimeInterval = 0.45
    /// Ghost lift scale while dragging.
    static let dragLiftScale: CGFloat = 1.15

    @Published var draggedID: String?
    /// The ghost's position object (see LCDesktopDragPosition): the
    /// only per-frame write in this state machine goes here, never
    /// into a @Published the desktop observes.
    let position = LCDesktopDragPosition()
    /// Last finger location (desktop space), for drop resolution and
    /// edge-flip checks. Plain var, not @Published: it is written
    /// every frame and only read from gesture handlers, never from a
    /// view body — publishing it would re-render the whole desktop
    /// per frame (0.0.4 follow fix).
    var dragLocation: CGPoint = .zero
    /// Last gesture translation. Written, never read anywhere (kept
    /// for the drag math's symmetry); plain var so the write is free.
    var dragTranslation: CGSize = .zero
    @Published var hoverIconID: String?
    @Published var hoverDockSlot: Int?
    /// Mirrors the edit state: the edit-mode drag gesture reads it mid-touch.
    @Published var isEditingForDrag = false
    /// Search disables dragging (see header).
    @Published var isSearchActive = false

    /// Grid cell frames in screen coordinates, keyed by icon id.
    @Published var cellFrames: [String: CGRect] = [:]
    /// Every rendered grid slot's frame (icon or empty), keyed by global
    /// slot index (page × 24 + cell) — so a drop on a blank slot lands.
    @Published var slotFrames: [Int: CGRect] = [:]
    /// Dock slot frames in screen coordinates, keyed by slot index.
    @Published var dockSlotFrames: [Int: CGRect] = [:]

    /// Last edge-flip time, for the 0.65 s cooldown.
    var lastEdgeFlipDate: Date?

    var isDragging: Bool { draggedID != nil }

    func beginDrag(id: String, at location: CGPoint) {
        guard !isSearchActive else { return }
        draggedID = id
        dragLocation = location
        position.location = location
        dragTranslation = .zero
        hoverIconID = nil
        hoverDockSlot = nil
    }

    func updateDrag(translation: CGSize, location: CGPoint) {
        dragTranslation = translation
        dragLocation = location
        // Only the ghost follows per frame (its own position object).
        position.location = location
        // Hover is the only @Published write here, and only on change:
        // assigning the same cell id every frame would still notify
        // and re-render the desktop per frame.
        // 0.0.5: the fixed Settings icon is not a drop target, so it
        // never gets the hover outline either.
        let hovered = iconID(at: location)
        let newHoverIcon = (hovered.map { LCDesktopIcon.isSystemID($0) } ?? false) ? nil : hovered
        if newHoverIcon != hoverIconID { hoverIconID = newHoverIcon }
        let newHoverDock = dockSlotIndex(at: location)
        if newHoverDock != hoverDockSlot { hoverDockSlot = newHoverDock }
    }

    /// Resolve the drop target from the current finger location.
    func resolveDrop() -> DesktopDrop {
        guard draggedID != nil else { return .none }
        if let dockSlot = dockSlotIndex(at: dragLocation) {
            return .dockSlot(dockSlot)
        }
        if let slot = slotIndex(at: dragLocation) {
            return .gridSlot(slot)
        }
        // Inside the Dock bar but on no icon: append.
        if isInDockBar(dragLocation) {
            return .dockAppend
        }
        return .none
    }

    func endDrag() {
        draggedID = nil
        dragTranslation = .zero
        position.location = .zero
        hoverIconID = nil
        hoverDockSlot = nil
        lastEdgeFlipDate = nil
    }

    /// The icon id whose cell frame contains the point, if any.
    func iconID(at point: CGPoint) -> String? {
        for (id, frame) in cellFrames where frame.contains(point) {
            return id
        }
        return nil
    }

    /// The grid slot index whose frame contains the point, if any.
    func slotIndex(at point: CGPoint) -> Int? {
        for (slot, frame) in slotFrames where frame.contains(point) {
            return slot
        }
        return nil
    }

    func dockSlotIndex(at point: CGPoint) -> Int? {
        for (slot, frame) in dockSlotFrames where frame.contains(point) {
            return slot
        }
        return nil
    }

    func isInDockBar(_ point: CGPoint) -> Bool {
        guard let screen = dockSlotFrames.values.first else { return false }
        // The Dock bar spans the bottom of the screen; any point below
        // the top of the lowest Dock slot frame and within the screen
        // width counts as "in the bar".
        let top = dockSlotFrames.values.map { $0.minY }.min() ?? 0
        return point.y >= top - 10 && point.y <= screen.maxY + 200
    }

    /// Edge direction while dragging, for the cross-page flip timer.
    func edgeDirection(at point: CGPoint, screenWidth: CGFloat) -> DesktopEdgeDirection? {
        if point.x <= Self.edgeFlipZoneWidth {
            return .previous
        }
        if point.x >= screenWidth - Self.edgeFlipZoneWidth {
            return .next
        }
        return nil
    }

    func edgeFlipReady() -> Bool {
        guard let last = lastEdgeFlipDate else { return true }
        return Date().timeIntervalSince(last) >= Self.edgeFlipCooldown
    }

    func markEdgeFlip() {
        lastEdgeFlipDate = Date()
    }
}

enum DesktopEdgeDirection {
    case previous
    case next
}

/// Grid cell frames in screen coordinates, keyed by icon id.
struct CellFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Every rendered grid slot's frame (icon or empty), keyed by global
/// slot index (page × 24 + cell).
struct SlotFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// The floating ghost: the dragged icon at 1.15× with a shadow,
/// following the finger. Shown by the desktop while a drag is active.
/// It observes ONLY the drag position object (LCDesktopDragPosition),
/// so per-frame finger movement re-renders this one icon + label and
/// nothing else — the desktop body is not re-run for the ghost.
///
/// 0.0.5: the ghost's frame is exactly the 58×58 icon, so .position
/// centres the ICON on the finger. The name hangs below the icon as
/// an overlay (it does not affect the frame). The old VStack (icon +
/// label) put the frame centre ~10pt below the icon centre, so the
/// icon floated ~10pt above the finger while dragging.
struct DesktopDragGhost: View {
    let icon: LCDesktopIcon
    let displayName: String
    @ObservedObject var position: LCDesktopDragPosition

    var body: some View {
        ZStack {
            if case .app(let model) = icon {
                AppIconImage(app: model, size: 58)
            }
        }
        .frame(width: 58, height: 58)
        .overlay(alignment: .bottom) {
            Text(displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: 76)
                .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1)
                // Label 4pt below the icon: bottom-aligned overlay
                // puts its bottom edge at the icon's bottom edge,
                // so shift it down by its own height (~15pt) + 4pt.
                .offset(y: 19)
        }
        .scaleEffect(LCDesktopDragState.dragLiftScale)
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 8)
        .position(position.location)
        .allowsHitTesting(false)
    }
}
