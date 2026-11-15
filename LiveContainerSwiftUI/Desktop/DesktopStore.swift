//
//  DesktopStore.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — desktop persistence and icon identity.
//
//  Replaces the deleted LCDesktopIcon.swift (same keys, same semantics):
//  the desktop slot order, Dock membership, launch counts and display-name
//  overrides all live in the App Group UserDefaults, shared with the
//  (deleted) LCAppSortManager's old store — no new database.
//
//  LCSystemPage lives here because the retained Shared.swift
//  (SharedModel.requestedSystemPage) references it; it must not die with
//  the deleted desktop files. The `view` computed property is gone on
//  purpose: the Sources / Tweaks / Settings pages it used to vend are
//  deleted, and the new Settings page (implementation #2) will consume
//  `requestedSystemPage` itself.
//
//  Research values (research-2026-11-15 §2.2.1): 24 icons per page,
//  4 Dock slots; Dock starts empty and only fills by user drag, except
//  for the first-run seed below (top 4 by launch count, once the user
//  has actually launched something — see LCDesktopDockStore.seedIfNeeded).

import Foundation
import SwiftUI

// MARK: - System pages

/// The non-App destinations reachable from the desktop. "Apps" itself is
/// excluded: Apps IS the desktop page.
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
    /// (Restored from 0.0.2 LCDesktopIcon.swift: the enum moved here in
    /// the 0.0.3 rebuild but the tint was dropped while DesktopGridCell
    /// still uses page.tint — CI Archive failed on the missing member.)
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
}

// MARK: - Unified desktop icon

/// One icon on the desktop grid / in the Dock. v1 carries IPA apps only;
/// system pages are not rendered as desktop icons (their pages are
/// rebuilt by implementation #2 and reached via deep link / certificate
/// gate), but the `.system` case stays so `LCSystemPage` deep links and
/// old persisted ids keep their meaning.
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

    /// True for imported IPA apps only. Shared apps are not deletable:
    /// their bundle and data are used by other instances, so — same rule
    /// as the old banner menu, which hid uninstall for them — they show
    /// no "−" badge.
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

    var isSystem: Bool {
        if case .system = self { return true }
        return false
    }

    /// True for a persisted icon id that belongs to a system page
    /// ("sys:sources" / "sys:tweaks" / "sys:settings").
    static func isSystemID(_ id: String) -> Bool {
        id.hasPrefix("sys:")
    }

    /// Unique id for an app model: "bundleId:relativePath".
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
/// list: each app owns a fixed slot, "" is an empty slot, and slots stay
/// empty — nothing auto-fills them, nothing re-sorts them. Newly
/// installed apps take the first free slot; removed apps free their slot
/// (they do not shift the icons after them). The order holds IPA apps
/// only; Dock members are not in it (an icon is either in the grid or
/// in the Dock, never both).
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

    /// First free slot (the first ""), or the end of the order if there
    /// is none — i.e. where a new / returning icon lands.
    func firstFreeSlot() -> Int {
        return order.firstIndex(of: "") ?? order.count
    }

    /// Sync with the installed apps: ids that no longer exist free their
    /// slot (they become "" — the icons after them do not move), and new
    /// ids take the first free slot each. Ids the caller excluded (Dock
    /// members) are freed the same way.
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

    /// Swap two icons' positions (a drop on an occupied cell swaps with
    /// that one cell only; all other icons stay put).
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

    /// Move `id` to exactly `slot` (drop on an empty cell — the icon
    /// stays exactly there). The old slot is freed; slots between are
    /// left as they are (padded with "" if the slot is past the end).
    /// This is a direct slot assignment, never an insert: inserting
    /// would shift every icon after the slot.
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
    /// Dock → grid occupant). Appends at the end if there is no free slot.
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

/// Persists Dock membership and order. The Dock starts empty: only icons
/// the user drags in are ever in it — except for the one-time first-run
/// seed (see seedIfNeeded), which fills it with the most-launched apps
/// once there is launch history to rank by. Once the user drags anything
/// (`LCDesktopDockManuallyEdited`), manual order wins and the seed never
/// runs again.
final class LCDesktopDockStore: ObservableObject {
    static let dockKey = "LCDesktopDockOrder"
    static let manuallyEditedKey = "LCDesktopDockManuallyEdited"
    static let maxDockItems = 4

    @Published private(set) var dockIDs: [String]

    init() {
        // The Dock holds imported apps only. An older build's Dock fill
        // included the three system icons, so any persisted "sys:" ids
        // are dropped here on launch.
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

    var isManuallyEdited: Bool {
        LCUtils.appGroupUserDefault.bool(forKey: Self.manuallyEditedKey)
    }

    private func markManuallyEdited() {
        LCUtils.appGroupUserDefault.set(true, forKey: Self.manuallyEditedKey)
    }

    /// One-time seed: if the Dock was never manually edited and is still
    /// empty, fill it with the `maxDockItems` most-launched apps. Called
    /// on every desktop sync; it is a no-op once the Dock is non-empty
    /// or the user has dragged anything. With no launch history yet the
    /// Dock stays empty — it never invents apps.
    func seedIfNeeded(launchCounts: [String: Int], allIDs: [String]) {
        guard !isManuallyEdited, dockIDs.isEmpty else { return }
        let ranked = allIDs.sorted { (launchCounts[$0] ?? 0) > (launchCounts[$1] ?? 0) }
        let seed = ranked.filter { (launchCounts[$0] ?? 0) > 0 }.prefix(Self.maxDockItems)
        guard !seed.isEmpty else { return }
        dockIDs = Array(seed)
        save()
    }

    /// Drop an icon into the Dock (appends; if the Dock is full, the last
    /// Dock icon is evicted and returned so the caller can put it back
    /// in the grid). Returns the evicted id, if any. Dropping on an
    /// occupied Dock slot is a swap instead — see replaceDockIcon.
    @discardableResult
    func addToDock(id: String) -> String? {
        // System icons never enter the Dock.
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
        markManuallyEdited()
        save()
        return evicted
    }

    /// Swap a Dock slot's icon (dropping on a Dock app swaps — that app
    /// returns to the dragged app's original grid cell; the caller puts
    /// it back there). No eviction: the Dock keeps its size.
    func replaceDockIcon(at index: Int, with id: String) {
        guard dockIDs.indices.contains(index),
              !LCDesktopIcon.isSystemID(id),
              !dockIDs.contains(id) else {
            return
        }
        var newDock = dockIDs
        newDock[index] = id
        dockIDs = newDock
        markManuallyEdited()
        save()
    }

    /// Swap two Dock slots (dragging within the Dock reorders it).
    func moveDockIcon(from fromIndex: Int, to toIndex: Int) {
        guard dockIDs.indices.contains(fromIndex), dockIDs.indices.contains(toIndex),
              fromIndex != toIndex else {
            return
        }
        var newDock = dockIDs
        newDock.swapAt(fromIndex, toIndex)
        dockIDs = newDock
        markManuallyEdited()
        save()
    }

    /// Drag an icon out of the Dock. Leaves an empty slot: nothing is
    /// auto-filled in, manual order wins.
    func removeFromDock(id: String) {
        guard dockIDs.contains(id) else {
            return
        }
        dockIDs.removeAll { $0 == id }
        markManuallyEdited()
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

// MARK: - Launch counts + display-name overrides

/// Launch counts (for the Dock seed) and desktop display-name overrides
/// (rename only changes what the desktop shows, never the bundle).
/// Both live in the App Group UserDefaults under the keys the research
/// report names (`LCDesktopLaunchCounts`).
final class LCDesktopMetaStore: ObservableObject {
    static let launchCountsKey = "LCDesktopLaunchCounts"
    static let displayNameOverridesKey = "LCDesktopDisplayNameOverrides"

    @Published private(set) var launchCounts: [String: Int]
    @Published private(set) var displayNameOverrides: [String: String]

    init() {
        self.launchCounts = LCUtils.appGroupUserDefault.dictionary(forKey: Self.launchCountsKey) as? [String: Int] ?? [:]
        self.displayNameOverrides = LCUtils.appGroupUserDefault.dictionary(forKey: Self.displayNameOverridesKey) as? [String: String] ?? [:]
    }

    func recordLaunch(id: String) {
        launchCounts[id, default: 0] += 1
        LCUtils.appGroupUserDefault.set(launchCounts, forKey: Self.launchCountsKey)
    }

    func displayName(for id: String, fallback: String) -> String {
        let override = displayNameOverrides[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return override.isEmpty ? fallback : override
    }

    /// Empty name is refused by the caller; a duplicate name is allowed
    /// (display names are not unique). Passing nil clears the override.
    func setDisplayName(_ name: String?, for id: String) {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            displayNameOverrides[id] = name
        } else {
            displayNameOverrides.removeValue(forKey: id)
        }
        LCUtils.appGroupUserDefault.set(displayNameOverrides, forKey: Self.displayNameOverridesKey)
    }

    func remove(id: String) {
        launchCounts.removeValue(forKey: id)
        displayNameOverrides.removeValue(forKey: id)
        LCUtils.appGroupUserDefault.set(launchCounts, forKey: Self.launchCountsKey)
        LCUtils.appGroupUserDefault.set(displayNameOverrides, forKey: Self.displayNameOverridesKey)
    }
}
