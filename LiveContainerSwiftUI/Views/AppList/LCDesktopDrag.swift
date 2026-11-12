//
//  LCDesktopDrag.swift
//  LiveContainerSwiftUI
//
//  Desktop grid v1: drag & drop for the desktop grid, cross-page drag and
//  Dock drag in / out.
//
//  Interaction model (demo spec §1, verified against the demo HTML — the
//  spec text alone is ambiguous on one point, see below):
//  - One gesture per icon: long-press (0.45 s, cancelled by > 9 pt of
//    movement) sequenced into a zero-distance drag. The drag listeners
//    attach on pointerdown regardless of edit mode, so the finger that
//    long-pressed into edit mode can keep moving and drag immediately —
//    no lift-and-re-press. SwiftUI's onDrag / onDrop cannot do this:
//    onDrag's internal press recogniser claims the touch before the
//    long-press fires, and a drag gesture attached mid-touch misses the
//    touch. The drag is therefore implemented by hand: a ghost icon
//    follows the finger 1:1 (grab offset preserved), the hovered cell is
//    hit-tested from the live cell frames, and the drop commits with the
//    demo's swap semantics (see below).
//  - Reorder semantics (demo §1.5, free placement, no auto-fill): drop
//    on an occupied cell SWAPS with that one cell only; all other icons
//    stay put. Drop on an empty cell moves the icon to exactly that
//    slot. Drop on a page's blank area lands at the end of that page.
//    Dock → occupied grid cell: the occupant moves to the first free
//    slot (the end of the order); the dragged icon takes the cell.
//    Grid → Dock icon: swap — that app returns to the dragged app's
//    original grid cell. Grid → empty Dock space: appends to the
//    Dock (evicting the last Dock icon if full). Dock → Dock: no change
//    (the demo flies back).
//  - NO live reflow: the demo does not shift icons during hover. Its
//    drag move handler only toggles the `.drop-hover` outline on the
//    hovered cell; the reorder happens on drop (finishDrag swaps). This
//    implementation matches that — it does not reflow during hover.
//  - Landing (demo §1.7): on drop the ghost flies to the target cell's
//    rect over 0.42 s on the no-overshoot curve, shrinking 1.15 → 1×
//    with the shadow falling back; the order commits at handoff. A
//    no-change drop flies back to the origin cell over 0.45 s.
//    pointercancel / backgrounding cancels the drag with no commit.
//  - Cross-page drag: while a drag is active, the finger within 24 pt
//    of the left / right screen edge flips one page; cooldown 650 ms
//    between flips, and the first flip needs 650 ms of dragging first
//    (lastFlip is set at drag start).
//

import Foundation
import SwiftUI

// MARK: - Drop target

/// Where a drag will land, resolved by hit-testing the finger against
/// the live cell / Dock frames. The hover highlight and the drop commit
/// both read this one value.
enum LCDesktopDropTarget: Equatable {
    /// A grid cell: drop swaps with the icon in this cell.
    case cell(id: String)
    /// An empty grid slot: drop moves the icon to exactly this slot
    /// (demo §1.5 — the slot stays empty until then, nothing
    /// auto-fills it).
    case emptySlot(slot: Int)
    /// A Dock slot occupied by `iconID`: drop swaps with that app.
    case dockSlot(index: Int, iconID: String)
    /// On the Dock bar but not on an occupied slot: drop appends.
    case dockAppend
    /// Blank area of `page`: drop lands at the end of that page.
    case pageEnd(page: Int)
    /// Invalid spot (or no target yet): drop flies back, no change.
    case none
}

/// Which way an edge page-flip goes.
enum LCDesktopEdgeDirection {
    case previous
    case next
}

// MARK: - Frame preferences (hit-testing)

/// Cell frames in the "desktop" coordinate space, keyed by icon id.
/// Reported by each grid cell (background GeometryReader); the drag
/// handler hit-tests the finger against the current page's cells.
struct LCDesktopCellFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Grid frames in the "desktop" coordinate space, keyed by page.
/// Reported by each page's grid; a drag over a page's blank area lands
/// at the end of that page.
struct LCDesktopGridFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Slot frames in the "desktop" coordinate space, keyed by global slot
/// index (page × 24 + cell). Reported by every rendered grid slot —
/// occupied cells and empty slots alike — so a drag can hit-test an
/// empty cell and land exactly there (demo §1.5).
struct LCDesktopSlotFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Dock frames in the "desktop" coordinate space: the bar itself plus
/// each of the 4 slots (occupied or empty), keyed by slot index.
struct LCDesktopDockFrames: Equatable {
    var bar: CGRect = .zero
    var slots: [Int: CGRect] = [:]
}

struct LCDesktopDockFramePreferenceKey: PreferenceKey {
    static var defaultValue: LCDesktopDockFrames = LCDesktopDockFrames()
    static func reduce(value: inout LCDesktopDockFrames, nextValue: () -> LCDesktopDockFrames) {
        let next = nextValue()
        if next.bar != .zero {
            value.bar = next.bar
        }
        value.slots.merge(next.slots) { $1 }
    }
}

// MARK: - Shared drag state

final class LCDesktopDragState: ObservableObject {
    /// Long-press that enters edit mode (demo §1.3): 450 ms, cancelled
    /// by > 9 pt of movement. The duration is ALWAYS 0.45 s, in edit
    /// mode too — see LCDesktopIconDragGesture below for why it must
    /// never be 0 in edit mode.
    static let longPressDuration: TimeInterval = 0.45
    static let longPressMaxMovement: CGFloat = 9
    /// Whether edit mode is on, mirrored here (reference type) so a
    /// gesture handler running mid-touch reads the CURRENT value.
    /// A gesture closure that reads the view's @State `isEditing`
    /// instead sees the value captured when the body was last
    /// evaluated — stale for the touch that just flipped it.
    /// Written only by enterEditMode() / exitEditMode().
    var isEditingForDrag = false
    /// Drag starts once the finger has moved this far after the
    /// long-press fired (demo §1.4). This is also the drag gesture's
    /// minimumDistance, so a tap (< 7 pt) never arms a drag and the
    /// delete badge / tap gestures keep working.
    static let dragStartDistance: CGFloat = 7
    /// Edge page-flip zone + cooldown (demo §1.6).
    static let edgeFlipZoneWidth: CGFloat = 24
    static let edgeFlipCooldown: TimeInterval = 0.65
    /// Landing (demo §1.7): 0.42 s, no overshoot; fly-back 0.45 s.
    static let landingDuration: TimeInterval = 0.42
    static let flyBackDuration: TimeInterval = 0.45
    /// The ghost icon's lift while dragging (demo §1.4).
    static let dragLiftScale: CGFloat = 1.15

    /// Id of the icon currently being dragged, if any.
    @Published var draggedID: String?
    /// The dragged icon (for the ghost tile).
    @Published var draggedIcon: LCDesktopIcon?
    /// True when the dragged icon came from the Dock.
    @Published var draggedFromDock = false
    /// The dragged icon's index in the grid order before the drag
    /// (grid icons only). A grid → Dock swap returns the Dock app to
    /// this cell.
    @Published var dragOriginIndex: Int?
    /// Where the drop will land, from the latest hit-test.
    @Published var dropTarget: LCDesktopDropTarget = .none
    /// Ghost centre in the "desktop" coordinate space (1:1 finger
    /// follow, grab offset preserved).
    @Published var ghostCenter: CGPoint = .zero
    /// Ghost scale: 1.15 while dragging, animated to 1.0 on landing.
    @Published var ghostScale: CGFloat = 1.0
    /// True while the ghost is flying to its landing cell.
    @Published var isLanding = false

    /// Live frames in the "desktop" coordinate space (from the
    /// preference keys above).
    @Published var cellFrames: [String: CGRect] = [:]
    @Published var gridFrames: [Int: CGRect] = [:]
    @Published var slotFrames: [Int: CGRect] = [:]
    @Published var dockFrame: CGRect = .zero
    @Published var dockSlotFrames: [Int: CGRect] = [:]

    /// Timestamp of the last edge page-flip (set at drag start, so the
    /// first flip needs a full cooldown of dragging first).
    var lastFlipTime: CFTimeInterval = 0
    /// The dragged cell's frame at drag start (ghost size + fallback
    /// landing centre).
    var dragStartFrame: CGRect = .zero
    /// The dragged cell's centre at drag start (the ghost's anchor).
    var dragStartCenter: CGPoint = .zero
    /// The finger's location when the drag phase started (the grab
    /// offset is `dragStartLocation - dragStartCenter`).
    var dragStartLocation: CGPoint = .zero

    var isDragging: Bool { draggedID != nil }
    /// True while the finger hovers the Dock (any Dock target).
    var isOverDock: Bool {
        switch dropTarget {
        case .dockSlot, .dockAppend:
            return true
        default:
            return false
        }
    }

    func beginDrag(icon: LCDesktopIcon, fromDock: Bool, originIndex: Int?, startCenter: CGPoint, startFrame: CGRect, startLocation: CGPoint) {
        guard draggedID == nil, !isLanding else { return }
        draggedID = icon.id
        draggedIcon = icon
        draggedFromDock = fromDock
        dragOriginIndex = originIndex
        dragStartCenter = startCenter
        dragStartFrame = startFrame
        dragStartLocation = startLocation
        ghostCenter = startCenter
        ghostScale = Self.dragLiftScale
        dropTarget = .none
        isLanding = false
        lastFlipTime = CACurrentMediaTime()
    }

    /// The ghost starts its landing flight (0.42 s, no overshoot). The
    /// caller animates ghostCenter / ghostScale inside withAnimation
    /// and commits at handoff.
    func beginLanding() {
        guard draggedID != nil, !isLanding else { return }
        isLanding = true
    }

    /// Handoff after the landing flight: the ghost goes away and the
    /// drag state clears. Idempotent.
    func finishLanding() {
        isLanding = false
        draggedID = nil
        draggedIcon = nil
        draggedFromDock = false
        dragOriginIndex = nil
        dropTarget = .none
        ghostScale = 1.0
    }

    /// Cancel (pointercancel / backgrounding): no commit, the grid
    /// restores. A landing already in flight is left to finish (the
    /// drop was already released; its commit runs at handoff).
    func cancelDrag() {
        guard !isLanding else { return }
        draggedID = nil
        draggedIcon = nil
        draggedFromDock = false
        dragOriginIndex = nil
        dropTarget = .none
        ghostScale = 1.0
    }

    /// Backgrounding ends a drag (same as cancel).
    func endDrag() {
        cancelDrag()
    }

    /// The drop target only changes when the hovered cell / slot
    /// changes, so the highlight (and any re-render) fires once per
    /// hover change, not on every move event.
    func setDropTarget(_ target: LCDesktopDropTarget) {
        if dropTarget != target {
            dropTarget = target
        }
    }
}

// MARK: - The icon drag gesture

/// One gesture per icon: long-press (0.45 s) sequenced into a drag
/// (minimumDistance 7 pt), so the finger that long-pressed into edit
/// mode can keep moving and drag immediately — no lift-and-re-press
/// (demo §1.4). The drag listeners attach on pointerdown regardless
/// of edit mode; a quick horizontal swipe fails the long-press
/// (> 9 pt) and goes to the pager instead.
///
/// THE LONG-PRESS DURATION IS CONSTANT (0.45 s) AND MUST NEVER DEPEND
/// ON `isEditing` — the old `isEditing ? 0 : 0.45` broke both tap and
/// drag (Q2 + Q5, run #49):
/// - Tap: with duration 0 in edit mode the long-press succeeds the
///   instant the finger lands, claiming the touch and failing the
///   cell's TapGesture before the finger can lift — every edit-mode
///   tap on an icon was dead, while a non-edit tap (0.45 s not yet
///   fired at lift-off) worked. A constant 0.45 s restores the tap
///   in both states: the finger lifts before it fires.
/// - Same-finger drag: the long-press itself flips `isEditing`
///   (enterEditMode), which re-renders the view and rebuilds this
///   gesture with a different minimumDuration. SwiftUI replaces the
///   in-flight gesture, the new one never saw the touch-down, and
///   the drag phase never starts — `beginDrag` is never reached.
///   With a constant duration the gesture struct is identical before
///   and after the edit flip, so the in-flight sequence survives it
///   and the same finger keeps dragging. `isEditing` is kept as a
///   parameter only so existing call sites do not change; it is
///   deliberately NOT read here.
/// Instant grab in edit mode (move > 7 pt, no hold, demo §1.4) is
/// provided separately by the plain DragGesture in LCAppListView
/// (desktopIconEditDragGesture), which is stable by construction —
/// it carries no edit-dependent parameter at all and gates on
/// LCDesktopDragState.isEditingForDrag at event time.
///
/// GUARD — the tap on the icon must stay NORMAL priority (see
/// LCDesktopGridCell): a high-priority tap outranks this sequence,
/// so the long-press can never succeed while the tap is still
/// possible, and the tap only fails past its ~10 pt tolerance —
/// already past this gesture's 9 pt maxDistance. That deadlock
/// made `beginDrag` unreachable from grid icons (the "drag is
/// completely gone" report, 2026-11-12): hold still and the tap
/// stays alive, move and the long-press fails first. Never raise
/// the icon tap back to high-priority.
///
/// The gesture is type-erased so both the grid cell and the Dock icon
/// can attach the same gesture from LCAppListView. The drag gesture's
/// minimumDistance is the 7 pt drag-start threshold: a tap (or a tap
/// on the delete badge) never arms a drag.
func LCDesktopIconDragGesture(
    icon: LCDesktopIcon,
    isInDock: Bool,
    isEditing: Bool,
    onLongPress: @escaping (LCDesktopIcon, Bool) -> Void,
    onDragChanged: @escaping (LCDesktopIcon, Bool, DragGesture.Value) -> Void,
    onDragEnded: @escaping (LCDesktopIcon, Bool, DragGesture.Value) -> Void
) -> AnyGesture<SequenceGesture<LongPressGesture, DragGesture>.Value> {
    _ = isEditing // Deliberately unused: see the doc comment above.
    let longPress = LongPressGesture(
        minimumDuration: LCDesktopDragState.longPressDuration,
        maximumDistance: LCDesktopDragState.longPressMaxMovement
    )
    let drag = DragGesture(minimumDistance: LCDesktopDragState.dragStartDistance, coordinateSpace: .named("desktop"))
    let sequence = longPress.sequenced(before: drag)
    return AnyGesture(
        sequence
            .onChanged { value in
                switch value {
                case .first(let pressed):
                    if pressed {
                        onLongPress(icon, isInDock)
                    }
                case .second(_, let dragValue):
                    if let dragValue {
                        onDragChanged(icon, isInDock, dragValue)
                    }
                }
            }
            .onEnded { value in
                if case .second(_, let dragValue) = value, let dragValue {
                    onDragEnded(icon, isInDock, dragValue)
                }
            }
    )
}
