//
//  SearchOverlay.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — pull-down search (system UI, implementation #2).
//
//  Research §1.6 / §3 step 9. The old search lived in the edit-mode
//  "···" menu; v1 moves it to a normal-mode gesture: pull down from the
//  middle of the home screen (NOT from the top edge — that is the
//  notification / control-center zone). The parent owns the gesture and
//  presents this overlay.
//
//  Behaviour:
//  - A floating search field at the top (magnifier + field + × clear +
//    Cancel), auto-focused when it appears.
//  - Searches the desktop display name (including rename overrides,
//    which the parent passes in) and the Bundle ID.
//  - No match shows "没有找到相关应用" — never a blank page.
//  - While searching, desktop dragging is disabled (the parent stops
//    feeding drag gestures) and the Dock stays put when the keyboard
//    rises (the Dock ignores the keyboard safe area; see DesktopView).
//  - Cancel (or dismissing) clears the query.

import Foundation
import SwiftUI

/// One searchable row. The parent builds these from the visible desktop
/// apps so rename overrides are searched under their display name.
struct SearchableApp: Identifiable {
    let id: String
    let displayName: String
    let bundleID: String
    let model: LCAppModel
}

struct SearchOverlay: View {
    let apps: [SearchableApp]
    @Binding var isPresented: Bool
    var onSelect: ((LCAppModel) -> Void)? = nil

    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [SearchableApp] {
        guard !trimmedQuery.isEmpty else { return apps }
        let needle = trimmedQuery.lowercased()
        return apps.filter {
            $0.displayName.lowercased().contains(needle)
                || $0.bundleID.lowercased().contains(needle)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Tap outside the results: dismiss (and clear the query).
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                // Floating search field.
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索应用", text: $query)
                        .focused($fieldFocused)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空")
                    }
                    Button("取消") { dismiss() }
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // Results.
                if results.isEmpty {
                    Text("没有找到相关应用")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results) { app in
                                Button {
                                    let model = app.model
                                    dismiss()
                                    onSelect?(model)
                                } label: {
                                    HStack(spacing: 12) {
                                        AppIconImage(app: app.model, size: 44)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(app.displayName)
                                                .font(.body)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text(app.bundleID)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
        }
        .onAppear {
            // Auto-focus so the keyboard is already up.
            Task { @MainActor in
                fieldFocused = true
            }
        }
    }

    private func dismiss() {
        query = ""
        fieldFocused = false
        isPresented = false
    }
}
