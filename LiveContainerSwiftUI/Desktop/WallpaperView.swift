//
//  WallpaperView.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — wallpaper.
//
//  Research §3 step 12: the default wallpaper is the bundled asset
//  (`DefaultWallpaper.imageset`, loaded with UIImage(named:)); a user
//  wallpaper only ever writes the App Group directory's `wallpaper.jpg`
//  — the bundled image is never overwritten, and restoring the default
//  just deletes the custom file. Fill is aspect-fill, centred, cropped
//  (never stretched). Page-turn parallax is −12pt per page on a 0.55 s
//  spring (research §2.2.1), applied by the desktop as an offset.

import Foundation
import SwiftUI

struct WallpaperView: View {
    /// Parallax offset for the current page (0 on page 0, −12 per page).
    var parallaxOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let custom = customWallpaperImage() {
                    Image(uiImage: custom)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if let bundled = UIImage(named: "DefaultWallpaper") {
                    Image(uiImage: bundled)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // No wallpaper asset at all: plain system background,
                    // never an invented image.
                    Color(.systemBackground)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .offset(x: parallaxOffset)
            .clipped()
        }
        .ignoresSafeArea()
    }

    /// The user's custom wallpaper, if one was written to the App Group.
    static func customWallpaperURL() -> URL? {
        LCSharedUtils.appGroupPath()?.appendingPathComponent("wallpaper.jpg")
    }

    private func customWallpaperImage() -> UIImage? {
        guard let url = Self.customWallpaperURL(),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return UIImage(data: data)
    }
}
