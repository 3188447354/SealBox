//
//  AppContextMenu.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — long-press icon menu.
//
//  Research §3 step 8: a normal-mode long-press (0.45 s) on an icon
//  shows a native-style contextMenu — 打开 / 重命名 / 查看详情 / 删除
//  (destructive) — plus "编辑主屏幕" to enter edit mode. Keep holding
//  after the menu appears does NOT enter edit mode by itself: SwiftUI's
//  contextMenu owns that touch, so the old hold-through path cannot be
//  reproduced on the same view; the menu item and the blank-area
//  long-press are the two edit entries in v1.

import Foundation
import SwiftUI

struct DesktopAppContextMenu: ViewModifier {
    let icon: LCDesktopIcon
    var onOpen: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil
    var onDetail: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onEditHomeScreen: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content.contextMenu {
            if let onOpen {
                Button {
                    onOpen()
                } label: {
                    Label("lc.menu.open".loc, systemImage: "arrow.up.forward.app")
                }
            }
            if let onRename {
                Button {
                    onRename()
                } label: {
                    Label("lc.menu.rename".loc, systemImage: "pencil")
                }
            }
            if let onDetail {
                Button {
                    onDetail()
                } label: {
                    Label("lc.menu.detail".loc, systemImage: "info.circle")
                }
            }
            if let onEditHomeScreen {
                Button {
                    onEditHomeScreen()
                } label: {
                    Label("lc.menu.editHomeScreen".loc, systemImage: "square.grid.3x3")
                }
            }
            if let onDelete, icon.isDeletable {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("lc.menu.delete".loc, systemImage: "trash")
                }
            }
        }
    }
}

extension View {
    func desktopAppContextMenu(
        _ icon: LCDesktopIcon,
        onOpen: (() -> Void)? = nil,
        onRename: (() -> Void)? = nil,
        onDetail: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onEditHomeScreen: (() -> Void)? = nil
    ) -> some View {
        modifier(DesktopAppContextMenu(
            icon: icon,
            onOpen: onOpen,
            onRename: onRename,
            onDetail: onDetail,
            onDelete: onDelete,
            onEditHomeScreen: onEditHomeScreen
        ))
    }
}
