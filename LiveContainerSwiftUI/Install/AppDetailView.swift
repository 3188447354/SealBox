//
//  AppDetailView.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — guest app detail page.
//
//  Full-screen cover with a Done button top-right (the only exit —
//  fullScreenCover has no swipe-to-dismiss). All data comes from the
//  model layer: LCAppInfo / LCAppModel / LCContainer. No mock data:
//  a value that cannot be read shows "—" instead of an invented value.
//  A signing failure at install time leaves the app unsigned; the page
//  marks that state "未签名 / JIT 启动" instead of hiding it.

import Foundation
import SwiftUI

struct AppDetailView: View {
    let app: LCAppModel
    var onDelete: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil

    @State private var bundleSizeText: String = "—"

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 16) {
                        AppIconImage(app: app, size: 60)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.displayName)
                                .font(.headline)
                            Text(app.version)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("lc.detail.info") {
                    detailRow("lc.detail.bundleId".loc, app.bundleIdentifier)
                    detailRow("lc.detail.version".loc, app.version)
                    detailRow("lc.detail.size".loc, bundleSizeText)
                    detailRow("lc.detail.installed".loc, installedDateText)
                    detailRow("lc.detail.containers".loc, "\(app.uiContainers.count)")
                    detailRow("lc.detail.signState".loc, signStateText)
                    detailRow("lc.detail.lastLaunch".loc, lastLaunchText)
                }
                if app.uiIsJITNeeded || app.uiIs32bit {
                    Section {
                        Text("lc.detail.jitNeeded".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    if let onRename {
                        Button("lc.detail.rename".loc, action: onRename)
                    }
                    if let onDelete {
                        Button("lc.detail.delete".loc, role: .destructive, action: onDelete)
                    }
                }
            }
            .navigationTitle(Text(app.displayName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.common.done".loc) {
                        onDone?()
                    }
                }
            }
        }
        .task {
            bundleSizeText = await bundleSize()
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var installedDateText: String {
        guard let date = app.appInfo.installationDate else { return "—" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    private var lastLaunchText: String {
        guard let date = app.appInfo.lastLaunched else { return "—" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    /// Unsigned (signing failed at install) is a real state, not an
    /// error to hide: such apps can still run on the JIT path.
    private var signStateText: String {
        if app.appInfo.dontSign {
            return "lc.detail.unsignedJIT".loc
        }
        return "lc.detail.signed".loc
    }

    private func bundleSize() async -> String {
        guard let bundlePath = app.appInfo.bundlePath() else { return "—" }
        let size = await Task.detached {
            var total: Int64 = 0
            let fm = FileManager.default
            let url = URL(fileURLWithPath: bundlePath)
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: nil) else {
                return Int64(0)
            }
            // Drive with nextObject(): Swift 6 forbids makeIterator()
            // from async contexts (see LCStorageManagementModel).
            while let fileURL = enumerator.nextObject() as? URL {
                if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let fileSize = values.fileSize {
                    total += Int64(fileSize)
                }
            }
            return total
        }.value
        guard size > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
