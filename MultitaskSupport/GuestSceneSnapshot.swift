//
//  GuestSceneSnapshot.swift
//  LiveContainer
//
//  SealBox 0.0.5 — switcher card snapshots (item 4).
//
//  The switcher card shows the guest app's own live screen, not an
//  icon placeholder. One source (0.0.7 — the virtual window is gone):
//  the guest runs in its own window scene. The registry holds
//  view:nil for these, so the scene's window is taken from
//  MultitaskWindowManager.sceneWindows (registered by
//  MultitaskAppWindow on appear).
//
//  A snapshot is taken ONCE when the card appears (plus one retry
//  1.5 s later if the first came back black), never per frame — a
//  live-updating card would cost a full-screen render every frame.
//  A near-black frame (guest still launching, or a window that never
//  rendered) is treated as "no picture" and the card falls back to
//  the icon placeholder — never a black rectangle presented as the
//  app. Nothing is invented: no snapshot, no fake screen.

import SwiftUI
import UIKit

enum GuestSceneSnapshot {
    /// The running container's dataUUID for a model, resolved through
    /// the switcher registry (the same lookup openSwitcher uses).
    @MainActor static func runningDataUUID(for app: LCAppModel) -> String? {
        guard #available(iOS 16.0, *) else { return nil }
        let uuids = Set(app.appInfo.containers.map { $0.folderName })
        return MultitaskDockManager.shared.apps.first { uuids.contains($0.appUUID) }?.appUUID
    }

    /// Snapshot the guest's live screen, or nil when there is nothing
    /// to show (not running, window not registered yet, or the frame
    /// came back near-black). Must be called on the main thread:
    /// drawHierarchy is main-thread only.
    @MainActor static func image(for app: LCAppModel) -> UIImage? {
        guard let dataUUID = runningDataUUID(for: app) else { return nil }
        // Native scene window (view is nil in native mode).
        if #available(iOS 16.1, *),
           let window = MultitaskWindowManager.sceneWindows[dataUUID]?.window {
            return snapshot(window: window)
        }
        return nil
    }

    @MainActor private static func snapshot(window: UIWindow) -> UIImage? {
        guard window.bounds.size.width > 0, window.bounds.size.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: window.bounds.size)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return isNearBlack(image) ? nil : image
    }

    /// True when the frame is (near-)all black: a guest still
    /// launching, or a window that never rendered. An 8×8 downscale
    /// is enough to tell a live screen (even a dark app has status
    /// bar / chrome pixels) from an unrendered surface.
    static func isNearBlack(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        guard let context = CGContext(
            data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 8 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return true }
        context.draw(cg, in: CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var total = 0
        for i in 0..<64 {
            total += Int(pixels[i * 4]) + Int(pixels[i * 4 + 1]) + Int(pixels[i * 4 + 2])
        }
        // Mean channel value below 6/255 across the frame == black.
        return total < 64 * 3 * 6
    }
}

/// A switcher card's picture: the guest's live screen when one can be
/// taken, the icon placeholder otherwise. The snapshot is taken once
/// when the card appears; if it came back black (guest still
/// launching) one retry follows 1.5 s later.
struct GuestAppSnapshotView: View {
    let app: LCAppModel
    @State private var snapshot: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 12) {
                    AppIconImage(app: app, size: 72)
                    Text(app.displayName)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(app.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("正在运行")
                        .font(.caption2.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.green.opacity(0.2)))
                        .foregroundStyle(.green)
                }
                .padding(16)
            }
        }
        .onAppear { refresh() }
        .task {
            // One retry if the first frame was black (guest still
            // launching when the switcher opened). No polling after
            // that: a card that stays black keeps the placeholder.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                if snapshot == nil {
                    refresh()
                }
            }
        }
    }

    @MainActor private func refresh() {
        snapshot = GuestSceneSnapshot.image(for: app)
    }
}
