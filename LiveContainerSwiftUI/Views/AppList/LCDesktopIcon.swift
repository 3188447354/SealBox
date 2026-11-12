//
//  LCDesktopIcon.swift
//  LiveContainerSwiftUI
//
//  Desktop grid v1: one unified icon identity for imported IPA apps,
//  plus the UserDefaults stores for desktop order and Dock membership.
//
//  Desktop position model (demo §1.5, free placement, no auto-fill):
//  every app owns a fixed slot in the persisted order and slots stay
//  empty — deleting or moving an icon frees its slot without shifting
//  any other icon. The order is a sparse slot list: "" is an empty
//  slot. The three system pages (Sources / Tweaks / Settings) are NOT
//  in this order at all: they are fixed-position icons rendered in
//  their own row, never dragged, never counted in the 24/page grid.
//
//  Persistence (all in the App Group defaults):
//    "LCDesktopIconOrder"          [String] sparse slot order, IPA ids
//                                  are "bundleId:relativePath"; ""
//                                  is an empty slot. No trailing ""
//                                  entries are kept.
//    "LCDesktopDockOrder"          [String] Dock member ids, in Dock order
//
//  The Dock starts empty (demo §4: seedDock = []): only icons the user
//  drags in are ever in it. There is no auto-fill and no launch-count
//  ranking.
//
//  TODO(BundleID): nothing here depends on the Bundle ID. The signing /
//  Bundle ID work (new ID for the standalone app) is still pending MJ's
//  decision; see DESKTOP_GRID_V1.md.
//

import Foundation
import SwiftUI

// MARK: - System pages exposed as desktop icons

/// The three non-Apps tabs, each reachable from a desktop icon instead of
/// the hidden Tab Bar. "Apps" itself is excluded: Apps IS the desktop page.
enum LCSystemPage: String, CaseIterable, Identifiable {
    case sources
    case tweaks
    case settings

    var id: String { "sys:\(rawValue)" }

    var title: String {
        switch self {
        case .sources:
            return "lc.tabView.sources".loc
        case .tweaks:
            return "lc.tabView.tweaks".loc
        case .settings:
            return "lc.tabView.settings".loc
        }
    }

    var systemImage: String {
        switch self {
        case .sources:
            return "books.vertical"
        case .tweaks:
            return "wrench.and.screwdriver"
        case .settings:
            return "gearshape.fill"
        }
    }

    /// Solid tint used for the icon tile, in the style of a system app icon.
    var tint: Color {
        switch self {
        case .sources:
            return .blue
        case .tweaks:
            return .orange
        case .settings:
            return .gray
        }
    }

    /// Reuses the existing tab View verbatim: no content or logic of the
    /// Sources / Tweaks / Settings pages is rewritten here.
    var view: AnyView {
        switch self {
        case .sources:
            return AnyView(LCSourcesView())
        case .tweaks:
            return AnyView(LCTweaksView())
        case .settings:
            return AnyView(LCSettingsView())
        }
    }
}

// MARK: - Unified desktop icon

/// One icon on the desktop grid / in the Dock. IPA apps and system pages
/// share the tile; only IPA apps take part in the slot order, drag and
/// Dock logic. System pages are fixed-position icons in their own row
/// (see the desktop view): they are never dragged, never in the order,
/// never in the Dock.
enum LCDesktopIcon: Hashable, Identifiable {
    case app(LCAppModel)
    case system(LCSystemPage)

    var id: String {
        switch self {
        case .app(let model):
            return LCDesktopIcon.appID(for: model)
        case .system(let page):
            return page.id
        }
    }

    var displayName: String {
        switch self {
        case .app(let model):
            return model.displayName
        case .system(let page):
            return page.title
        }
    }

    /// True for imported IPA apps only. System icons are permanent: they
    /// have no delete badge in the grid and cannot be deleted. Shared
    /// apps are not deletable either: their bundle and data are used by
    /// other instances, so — same rule as the banner menu, which hides
    /// uninstall for them — they show no "−" badge.
    var isDeletable: Bool {
        switch self {
        case .app(let model):
            return !model.uiIsShared
        case .system:
            return false
        }
    }

    var appModel: LCAppModel? {
        switch self {
        case .app(let model):
            return model
        case .system:
            return nil
        }
    }

    /// True for the three system-page icons (Sources / Tweaks /
    /// Settings). They live in the fixed system row; they never enter
    /// the Dock or the slot order.
    var isSystem: Bool {
        if case .system = self { return true }
        return false
    }

    /// True for a persisted icon id that belongs to a system page
    /// ("sys:sources" / "sys:tweaks" / "sys:settings").
    static func isSystemID(_ id: String) -> Bool {
        id.hasPrefix("sys:")
    }

    /// Unique id for an app model: "bundleId:relativePath". (Was
    /// LCAppSortManager.getUniqueIdentifier; moved here when the sort
    /// system was deleted — the desktop slot order is the only user.)
    static func appID(for model: LCAppModel) -> String {
        if let bundleId = model.appInfo.bundleIdentifier(),
           let relativePath = model.appInfo.relativeBundlePath {
            return "\(bundleId):\(relativePath)"
        }
        // Fallback for models without a bundle id / relative path yet.
        return model.appInfo.relativeBundlePath ?? model.displayName
    }
}

// MARK: - Desktop order store

/// Persists the dragged order of every desktop icon as a sparse slot
/// list (demo §1.5): each app owns a fixed slot, "" is an empty slot,
/// and slots stay empty — nothing auto-fills them, nothing re-sorts
/// them. Newly installed apps take the first free slot; removed apps
/// free their slot (they do not shift the icons after them). The
/// order holds IPA apps only: system-page icons are fixed-position
/// and never enter it, and Dock members are not in it either (an icon
/// is either in the grid or in the Dock, never both).
final class LCDesktopOrderStore: ObservableObject {
    static let orderKey = "LCDesktopIconOrder"

    @Published private(set) var order: [String]

    init() {
        self.order = LCUtils.appGroupUserDefault.array(forKey: Self.orderKey) as? [String] ?? []
    }

    private func save() {
        LCUtils.appGroupUserDefault.set(order, forKey: Self.orderKey)
    }

    /// Drop trailing empty slots: the order ends at the last occupied
    /// slot, so trailing gaps never create phantom pages.
    private func trimTrailingEmpty(_ slots: [String]) -> [String] {
        var result = slots
        while result.last == "" {
            result.removeLast()
        }
        return result
    }

    /// First free slot (the first ""), or the end of the order if
    /// there is none — i.e. where a new / returning icon lands.
    func firstFreeSlot() -> Int {
        return order.firstIndex(of: "") ?? order.count
    }

    /// Sync with the installed apps: ids that no longer exist free
    /// their slot (they become "" — the icons after them do not move),
    /// and new ids take the first free slot each. Ids the caller
    /// excluded (Dock members) are freed the same way.
    func sync(allIDs: [String]) {
        let known = Set(allIDs)
        var newOrder = order.map { known.contains($0) ? $0 : "" }
        for id in allIDs where !newOrder.contains(id) {
            if let free = newOrder.firstIndex(of: "") {
                newOrder[free] = id
            } else {
                newOrder.append(id)
            }
        }
        newOrder = trimTrailingEmpty(newOrder)
        if newOrder != order {
            order = newOrder
            save()
        }
    }

    /// Swap two icons' positions (demo §1.5: a drop on an occupied cell
    /// swaps with that one cell only; all other icons stay put).
    func swap(id: String, withID otherID: String) {
        guard id != otherID,
              let i = order.firstIndex(of: id),
              let j = order.firstIndex(of: otherID) else {
            return
        }
        order.swapAt(i, j)
        save()
    }

    /// Replace one id with another at the same position (Dock → grid:
    /// the dragged icon takes the cell; the caller puts the displaced
    /// id in the first free slot).
    func replace(id: String, with newID: String) {
        guard let i = order.firstIndex(of: id) else {
            return
        }
        var newOrder = order
        newOrder[i] = newID
        order = newOrder
        save()
    }

    /// Move `id` to exactly `slot` (demo §1.5: drop on an empty cell —
    /// the icon stays exactly there). The old slot is freed; slots
    /// between are left as they are (padded with "" if the slot is
    /// past the end, e.g. a drop on the extra blank page in edit
    /// mode). This is a direct slot assignment, never an insert:
    /// inserting would shift every icon after the slot.
    func moveToSlot(id: String, slot: Int) {
        guard !id.isEmpty, slot >= 0 else {
            return
        }
        var newOrder = order
        if let old = newOrder.firstIndex(of: id) {
            newOrder[old] = ""
        }
        while newOrder.count <= slot {
            newOrder.append("")
        }
        newOrder[slot] = id
        order = trimTrailingEmpty(newOrder)
        save()
    }

    /// Put `id` in the first free slot (new installs, Dock evictions,
    /// Dock "−", Dock → grid occupant). Appends at the end if there
    /// is no free slot.
    func placeInFirstFreeSlot(id: String) {
        moveToSlot(id: id, slot: firstFreeSlot())
    }

    /// Free `id`'s slot (delete, or leaving for the Dock). The slot
    /// becomes "" — the icons after it do not shift.
    func remove(id: String) {
        guard let i = order.firstIndex(of: id) else {
            return
        }
        var newOrder = order
        newOrder[i] = ""
        order = trimTrailingEmpty(newOrder)
        save()
    }
}

// MARK: - Dock store

/// Persists Dock membership and order. The Dock starts empty (demo
/// §4: seedDock = []): only icons the user drags in are ever in it.
/// There is no auto-fill — no launch-count ranking, no initial fill.
final class LCDesktopDockStore: ObservableObject {
    static let dockKey = "LCDesktopDockOrder"
    static let maxDockItems = 4

    @Published private(set) var dockIDs: [String]

    init() {
        // The Dock holds imported apps only. An older build's Dock
        // fill included the three system icons, so any persisted
        // "sys:" ids are dropped here on launch; those icons live in
        // the fixed system row.
        let stored = LCUtils.appGroupUserDefault.array(forKey: Self.dockKey) as? [String] ?? []
        let cleaned = stored.filter { !LCDesktopIcon.isSystemID($0) }
        self.dockIDs = cleaned
        if cleaned.count != stored.count {
            LCUtils.appGroupUserDefault.set(cleaned, forKey: Self.dockKey)
        }
    }

    private func save() {
        LCUtils.appGroupUserDefault.set(dockIDs, forKey: Self.dockKey)
    }

    /// Drop an icon into the Dock (demo §4: appends to the Dock; if the
    /// Dock is full, the last Dock icon is evicted and returned so the
    /// caller can put it back in the grid). Returns the evicted id, if
    /// any. Dropping on an occupied Dock slot is a swap instead — see
    /// replaceDockIcon(at:with:).
    @discardableResult
    func addToDock(id: String) -> String? {
        // System icons never enter the Dock: they live in the fixed
        // system row.
        guard !LCDesktopIcon.isSystemID(id) else {
            return nil
        }
        var evicted: String?
        var newDock = dockIDs.filter { $0 != id }
        if newDock.count >= Self.maxDockItems {
            evicted = newDock.removeLast()
        }
        newDock.append(id)
        dockIDs = newDock
        save()
        return evicted
    }

    /// Swap a Dock slot's icon (demo §4: dropping on a Dock app swaps —
    /// that app returns to the dragged app's original grid cell; the
    /// caller puts it back there). No eviction: the Dock keeps its size.
    func replaceDockIcon(at index: Int, with id: String) {
        guard dockIDs.indices.contains(index),
              !LCDesktopIcon.isSystemID(id),
              !dockIDs.contains(id) else {
            return
        }
        var newDock = dockIDs
        newDock[index] = id
        dockIDs = newDock
        save()
    }

    /// Drag an icon out of the Dock. Leaves an empty slot: nothing is
    /// auto-filled in, manual order wins.
    func removeFromDock(id: String) {
        guard dockIDs.contains(id) else {
            return
        }
        dockIDs.removeAll { $0 == id }
        save()
    }

    /// Remove an icon everywhere (app deleted from the grid).
    func removeEverywhere(id: String) {
        guard dockIDs.contains(id) else {
            return
        }
        dockIDs.removeAll { $0 == id }
        save()
    }
}

// MARK: - Shared icon tile

/// The icon tile shared by the grid cell, the Dock icon and the drag
/// ghost: an imported app's icon, or a solid-tint rounded rect with an
/// SF Symbol for a system page. Corner radius and glyph scale with the
/// tile size (60 pt grid / 56 pt Dock), so all three stay identical.
struct LCDesktopIconTile: View {
    let icon: LCDesktopIcon
    let darkModeIcon: Bool
    let size: CGFloat

    var body: some View {
        Group {
            switch icon {
            case .app(let model):
                IconImageView(icon: model.appInfo.iconIsDarkIcon(darkModeIcon))
            case .system(let page):
                RoundedRectangle(cornerRadius: size * 0.2667)
                    .fill(page.tint)
                    .overlay {
                        Image(systemName: page.systemImage)
                            .font(.system(size: size * 0.43, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
    }
}
