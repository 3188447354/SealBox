//
//  RenameAlert.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — rename.
//
//  Research §3 step 8: renaming only changes the desktop display-name
//  override (LCDesktopMetaStore). It never touches the bundle's
//  CFBundleDisplayName or the Bundle ID. An empty name is refused;
//  a duplicate name is allowed (display names are not unique).
//
//  A sheet with a TextField, not a SwiftUI alert: alert text fields need
//  iOS 16+, and the deployment target is iOS 15.

import Foundation
import SwiftUI

struct RenameSheet: View {
    let app: LCAppModel
    var onSave: (String) -> Void
    var onCancel: (() -> Void)? = nil

    @State private var name: String

    init(app: LCAppModel, initialName: String, onSave: @escaping (String) -> Void, onCancel: (() -> Void)? = nil) {
        self.app = app
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("lc.rename.placeholder".loc, text: $name)
                        .autocorrectionDisabled()
                } footer: {
                    Text("lc.rename.hint".loc)
                        .font(.footnote)
                }
            }
            .navigationTitle("lc.rename.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc) {
                        onCancel?()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.common.save".loc) {
                        onSave(name)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
