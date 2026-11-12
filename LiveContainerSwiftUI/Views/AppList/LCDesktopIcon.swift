//
//  LCDesktopIcon.swift
//  LiveContainerSwiftUI
//
//  Desktop grid v1: one unified icon identity for imported IPA apps and the
//  three system pages (Sources / Tweaks / Settings), plus the UserDefaults
//  stores for desktop order, Dock membership and launch counts.
//
//  Persistence (all in the App Group defaults, same store LCAppSortManager
//  uses for "LCCustomSortOrder"; no new database):
//    "LCDesktopIconOrder"          [String] unified icon order, IPA ids are
//                                  "bundleId:relativePath" (same format as
//                                  LCAppSortManager.getUniqueIdentifier),
//                                  system icons are "sys:sources" /
//                                  "sys:tweaks" / "sys:settings"
//    "LCDesktopDockOrder"          [String] Dock member ids, in Dock order
//    "LCDesktopDockManuallyEdited" Bool, true once the user drags anything
//                                  into / out of the Dock by hand
//    "LCDesktopLaunchCounts"       [String: Int] launches per icon id
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
/// share the same ordering, drag and Dock logic and the same order store.
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
    /// Settings). They live in the grid; they never enter the Dock.
    var isSystem: Bool {
        if case .system = self { return true }
        return false
    }

    /// True for a persisted icon id that belongs to a system page
    /// ("sys:sources" / "sys:tweaks" / "sys:settings").
    static func isSystemID(_ id: String) -> Bool {
        id.hasPrefix("sys:")
    }

    static func appID(for model: LCAppModel) -> String {
        if let uniqueID = LCAppSortManager.shared.getUniqueIdentifier(for: model) {
            return uniqueID
        }
        // Fallback for models without a bundle id / relative path yet.
        return model.appInfo.relativeBundlePath ?? model.displayName
    }
}

// MARK: - Desktop order store

/// Persists the dragged order of every desktop icon. Newly installed apps
/// (and the three system icons on first run) are appended at the end;
/// removed apps are pruned. The order is independent of
/// LCAppSortManager.appSortType: on the desktop, the manual order is what
/// the user sees. (Known limitation, see DESKTOP_GRID_V1.md: the desktop
/// order and the list sorter's custom order are two stores; the desktop
/// does not write back into "LCCustomSortOrder".)
final class LCDesktopOrderStore: ObservableObject {
    static let orderKey = "LCDesktopIconOrder"

    @Published private(set) var order: [String]

    init() {
        self.order = LCUtils.appGroupUserDefault.array(forKey: Self.orderKey) as? [String] ?? []
    }

    private func save() {
        LCUtils.appGroupUserDefault.set(order, forKey: Self.orderKey)
    }

    /// Prune ids that no longer exist, append new ids at the end.
    func sync(allIDs: [String]) {
        let known = Set(allIDs)
        var newOrder = order.filter { known.contains($0) }
        for id in allIDs where !newOrder.contains(id) {
            newOrder.append(id)
        }
        if newOrder != order {
            order = newOrder
            save()
        }
    }

    /// Move `id` to just before `targetID` (the displaced icons make
    /// room). No-op if either id is missing or they are the same.
    func move(id: String, beforeID targetID: String) {
        guard id != targetID, order.contains(id), order.contains(targetID) else {
            return
        }
        var newOrder = order.filter { $0 != id }
        guard let targetIndex = newOrder.firstIndex(of: targetID) else {
            return
        }
        newOrder.insert(id, at: targetIndex)
        order = newOrder
        save()
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
    /// the dragged icon takes the cell; the caller appends the
    /// displaced id at the end, the first free slot).
    func replace(id: String, with newID: String) {
        guard let i = order.firstIndex(of: id) else {
            return
        }
        var newOrder = order
        newOrder[i] = newID
        order = newOrder
        save()
    }

    /// Insert at a global index (used when dropping onto a page).
    func insert(id: String, at index: Int) {
        var newOrder = order.filter { $0 != id }
        let clamped = max(0, min(index, newOrder.count))
        newOrder.insert(id, at: clamped)
        order = newOrder
        save()
    }

    func remove(id: String) {
        guard order.contains(id) else {
            return
        }
        order.removeAll { $0 == id }
        save()
    }
}

// MARK: - Dock store

/// Persists Dock membership and order. Manual order wins once the user has
/// dragged anything: launch counts only do the initial fill.
final class LCDesktopDockStore: ObservableObject {
    static let dockKey = "LCDesktopDockOrder"
    static let manuallyEditedKey = "LCDesktopDockManuallyEdited"
    static let maxDockItems = 4

    @Published private(set) var dockIDs: [String]
    @Published private(set) var manuallyEdited: Bool

    init() {
        // The Dock holds imported apps only. An older build's Dock
        // fill included the three system icons, so any persisted
        // "sys:" ids are dropped here on launch; the order sync puts
        // them back in the grid.
        let stored = LCUtils.appGroupUserDefault.array(forKey: Self.dockKey) as? [String] ?? []
        let cleaned = stored.filter { !LCDesktopIcon.isSystemID($0) }
        self.dockIDs = cleaned
        self.manuallyEdited = LCUtils.appGroupUserDefault.bool(forKey: Self.manuallyEditedKey)
        if cleaned.count != stored.count {
            LCUtils.appGroupUserDefault.set(cleaned, forKey: Self.dockKey)
        }
    }

    private func save() {
        LCUtils.appGroupUserDefault.set(dockIDs, forKey: Self.dockKey)
        LCUtils.appGroupUserDefault.set(manuallyEdited, forKey: Self.manuallyEditedKey)
    }

    /// Initial fill from launch counts. Never called once manuallyEdited.
    func autoFill(topIDs: [String]) {
        guard !manuallyEdited else {
            return
        }
        let filled = Array(topIDs.prefix(Self.maxDockItems))
        if filled != dockIDs {
            dockIDs = filled
            save()
        }
    }

    /// Drop an icon into the Dock (demo §4: appends to the Dock; if the
    /// Dock is full, the last Dock icon is evicted and returned so the
    /// caller can put it back in the grid). Returns the evicted id, if
    /// any. Dropping on an occupied Dock slot is a swap instead — see
    /// replaceDockIcon(at:with:).
    @discardableResult
    func addToDock(id: String) -> String? {
        // System icons never enter the Dock: they live in the grid.
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
        manuallyEdited = true
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
        manuallyEdited = true
        save()
    }

    /// Drag an icon out of the Dock. Leaves an empty slot: nothing is
    /// auto-filled in, manual order wins.
    func removeFromDock(id: String) {
        guard dockIDs.contains(id) else {
            return
        }
        dockIDs.removeAll { $0 == id }
        manuallyEdited = true
        save()
    }

    /// Remove an icon everywhere (app deleted from the grid). If the Dock
    /// was never manually edited, the caller refills it via autoFill.
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

// MARK: - Launch counts

/// Simple UserDefaults launch counter. Only used for the Dock's initial
/// fill (most-used first) and as a tiebreak; never a database.
enum LCDesktopLaunchCountStore {
    static let countsKey = "LCDesktopLaunchCounts"

    static func recordLaunch(id: String) {
        var counts = LCUtils.appGroupUserDefault.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        counts[id, default: 0] += 1
        LCUtils.appGroupUserDefault.set(counts, forKey: countsKey)
    }

    static func counts() -> [String: Int] {
        return LCUtils.appGroupUserDefault.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
    }

    /// Ids sorted by launch count, most launched first. Ids with no launches
    /// sort last, in the order given by `fallbackOrder`.
    static func topIDs(limit: Int, fallbackOrder: [String]) -> [String] {
        let counts = counts()
        let ranked = fallbackOrder.sorted { lhs, rhs in
            (counts[lhs] ?? 0) > (counts[rhs] ?? 0)
        }
        return Array(ranked.prefix(limit))
    }
}
