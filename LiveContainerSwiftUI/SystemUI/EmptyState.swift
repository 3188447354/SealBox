//
//  EmptyState.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — empty desktop + first-edit coach mark
//  (system UI, implementation #2).
//
//  Research §3 step 12. An empty desktop is just the wallpaper: zero
//  copy, no "tap + to install" guidance, no counter footer. The single
//  exception is the coach mark below: the first time the user long-
//  presses into edit mode with no apps installed, a light hint appears
//  next to the "+" capsule. Tapping anywhere dismisses it, and it is
//  never shown again (the "shown" flag is persisted the moment it
//  first appears, so leaving edit mode does not re-arm it).

import Foundation
import SwiftUI

/// Persistence for the one-time coach mark.
enum EmptyStateCoachMarkStore {
    static let shownKey = "LCEmptyStateCoachMarkShown"

    static var shownBefore: Bool {
        LCUtils.appGroupUserDefault.bool(forKey: shownKey)
    }

    static func markShown() {
        LCUtils.appGroupUserDefault.set(true, forKey: shownKey)
    }
}

/// The one-time hint beside the edit-mode "+" capsule. The parent
/// decides when to show it (empty desktop + first edit-mode entry);
/// this view only renders and dismisses.
struct EmptyStateCoachMark: View {
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.left")
                .font(.system(size: 12, weight: .semibold))
            Text("点 + 导入 IPA")
                .font(.footnote.bold())
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .onAppear {
            EmptyStateCoachMarkStore.markShown()
        }
        .onTapGesture {
            onDismiss?()
        }
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}
