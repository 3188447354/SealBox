//
//  AppContextMenu.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.5 — long-press icon menu (custom overlay).
//
//  The old implementation was a SwiftUI contextMenu. It owned the
//  long-press touch, so a normal-mode long-press could never turn
//  into a drag (item 7): the menu always won and hold-through
//  dragging was edit-mode only. The menu is now a custom overlay
//  shown by the desktop when a long-press ends WITHOUT a drag; the
//  same long-press starts a drag when the finger moves (the
//  sequenced LongPress -> Drag gesture in DesktopView /
//  DesktopDockView). Same five actions (Open / Rename / View
//  Details / Edit Home Screen / Delete), same trigger, no system
//  menu. Labels come from the catalog (lc.menu.*, added in 0.0.5).

import Foundation
import SwiftUI

/// One menu request: which icon, and where it sits (desktop space).
struct DesktopMenuRequest: Identifiable {
    let id = UUID()
    let icon: LCDesktopIcon
    let anchor: CGPoint
}

/// The long-press menu, drawn next to the pressed icon. Dismisses
/// on tap outside or after an action.
struct DesktopAppMenuOverlay: View {
    let request: DesktopMenuRequest
    var onOpen: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil
    var onDetail: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onEditHomeScreen: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    private struct MenuRow {
        let titleKey: String
        let systemImage: String
        let isDestructive: Bool
        let action: () -> Void
    }

    private var rows: [MenuRow] {
        var rows: [MenuRow] = []
        if let onOpen {
            rows.append(MenuRow(titleKey: "lc.menu.open", systemImage: "arrow.up.forward.app", isDestructive: false, action: onOpen))
        }
        if let onRename {
            rows.append(MenuRow(titleKey: "lc.menu.rename", systemImage: "pencil", isDestructive: false, action: onRename))
        }
        if let onDetail {
            rows.append(MenuRow(titleKey: "lc.menu.detail", systemImage: "info.circle", isDestructive: false, action: onDetail))
        }
        if let onEditHomeScreen {
            rows.append(MenuRow(titleKey: "lc.menu.editHomeScreen", systemImage: "square.grid.3x3", isDestructive: false, action: onEditHomeScreen))
        }
        if let onDelete, request.icon.isDeletable {
            rows.append(MenuRow(titleKey: "lc.menu.delete", systemImage: "trash", isDestructive: true, action: onDelete))
        }
        return rows
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Tap outside: dismiss. Near-transparent so it still
                // hit-tests over the whole screen.
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss?() }
                menuCard(size: geometry.size)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func menuCard(size: CGSize) -> some View {
        // One 48pt row per action + 8pt padding top/bottom.
        let cardWidth: CGFloat = 250
        let cardHeight = CGFloat(rows.count * 48 + 16)
        // Above the icon when it sits in the lower half, below it
        // otherwise; clamped so the card never leaves the screen.
        let above = request.anchor.y > size.height * 0.5
        let centerY = above
            ? request.anchor.y - 110 - cardHeight / 2
            : request.anchor.y + 110 + cardHeight / 2
        let clampedY = min(max(centerY, cardHeight / 2 + 12), size.height - cardHeight / 2 - 12)
        let clampedX = min(max(request.anchor.x, cardWidth / 2 + 12), size.width - cardWidth / 2 - 12)
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                Button(role: row.isDestructive ? .destructive : nil) {
                    row.action()
                } label: {
                    HStack {
                        Label(row.titleKey.loc, systemImage: row.systemImage)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                }
                .buttonStyle(.plain)
                if index < rows.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .frame(width: cardWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: 8)
        .position(x: clampedX, y: clampedY)
    }
}
