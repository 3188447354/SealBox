//
//  DeleteConfirmSheet.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — delete confirmation.
//
//  Research §3 step 8: the confirmation says everything once — the app
//  bundle, all its data containers and its keychain records are deleted
//  and the operation cannot be undone — with the two buttons
//  "删除应用 / 取消". Confirming calls LCAppModel.uninstallFiles, the
//  real delete (bundle folder + every data container + keychain items +
//  DataManager registry entry). If the file delete fails the desktop
//  does not move — only an error is shown. Shared apps never reach
//  here: the grid shows no "−" for them and the context menu hides
//  Delete for them (the second line of defence).

import Foundation
import SwiftUI

struct DeleteConfirmSheet: View {
    let app: LCAppModel
    var onConfirm: () -> Void
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Text("lc.delete.title".loc)
                .font(.headline)
            Text("lc.delete.body".loc)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(app.displayName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                onConfirm()
            } label: {
                Text("lc.delete.confirm".loc)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button("lc.common.cancel".loc) {
                onCancel?()
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .presentationDetentsIfAvailable()
    }
}

extension View {
    /// Medium detent on iOS 16+, plain sheet on iOS 15.
    @ViewBuilder
    func presentationDetentsIfAvailable() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium])
        } else {
            self
        }
    }
}
