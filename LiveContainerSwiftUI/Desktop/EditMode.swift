//
//  EditMode.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — edit-mode state machine.
//
//  Research §1.2 / §4 #35: long-press on blank desktop (0.45 s, the
//  constant from DesktopDrag) enters edit mode; tapping blank exits,
//  with a 400 ms exit guard (exiting within 400 ms of entering is
//  ignored — it is almost always the same touch that entered).
//  Edit mode shows the left-top "+" capsule (install entry A) and the
//  right-top "···" menu. Three taps on blank desktop unlock hidden apps
//  (the old counter-footer gesture, moved off the deleted footer).
//  The "···" menu's search entry is gone: search is a normal-mode
//  pull-down gesture in implementation #2's SearchOverlay, not an
//  edit-mode menu item.

import Foundation
import SwiftUI

final class DesktopEditState: ObservableObject {
    @Published private(set) var isEditing = false
    @Published private(set) var hiddenUnlocked = false

    /// Entry time, for the 400 ms exit guard.
    private var enteredAt: Date?
    /// Triple-tap bookkeeping for the hidden-app unlock.
    private var blankTapCount = 0
    private var lastBlankTap: Date?

    /// 400 ms exit guard: true only once 400 ms have passed since entry.
    var canExit: Bool {
        guard let enteredAt else { return true }
        return Date().timeIntervalSince(enteredAt) >= 0.4
    }

    func enter() {
        guard !isEditing else { return }
        isEditing = true
        enteredAt = Date()
    }

    func exit() {
        guard isEditing, canExit else { return }
        isEditing = false
        enteredAt = nil
    }

    /// Blank-desktop tap: exits edit mode (guarded), and counts toward
    /// the triple-tap hidden-app unlock when not editing.
    func blankTapped() {
        if isEditing {
            exit()
            return
        }
        let now = Date()
        if let last = lastBlankTap, now.timeIntervalSince(last) < 1.0 {
            blankTapCount += 1
        } else {
            blankTapCount = 1
        }
        lastBlankTap = now
        if blankTapCount >= 3 {
            blankTapCount = 0
            hiddenUnlocked = true
            DataManager.shared.model.isHiddenAppUnlocked = true
        }
    }
}

/// The "+" capsule, top-left in edit mode only: install entry A.
struct EditModePlusCapsule: View {
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Capsule().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
    }
}

/// The "···" menu, top-right in edit mode only. v1 offers just "完成":
/// search moved to the normal-mode pull-down gesture (#2), and there is
/// no theme switcher in the rebuild.
struct EditModeMenu: View {
    var onDone: () -> Void

    var body: some View {
        Menu {
            Button("lc.edit.done".loc, action: onDone)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Capsule().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
    }
}
