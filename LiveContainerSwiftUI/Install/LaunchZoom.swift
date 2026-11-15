//
//  LaunchZoom.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — launch zoom opening.
//
//  Research §2.2.3: tapping an icon first plays the icon-anchored zoom
//  opening — the window starts at scale 0.12 / corner radius 44 around
//  the tapped icon's centre, then expands, with a 460 ms wait so signing
//  / launch preparation has time. The zoom overlay stays up until runApp
//  returns; on launch failure it is removed and the error alert takes
//  over — never a fake opening to nowhere.

import Foundation
import SwiftUI

/// Zoom-opening state, owned by the desktop. The anchor is the tapped
/// icon's centre in screen coordinates (from the drag hit-test frames).
final class LaunchZoomState: ObservableObject {
    @Published var isActive = false
    @Published var anchor: UnitPoint = .center
    @Published var scale: CGFloat = 1.0
    @Published var opacity: Double = 1.0
    @Published var radius: CGFloat = 0

    static let zoomScale: CGFloat = 0.12
    static let zoomRadius: CGFloat = 44
    /// 460 ms wait while signing / launch preparation runs.
    static let zoomWaitNanoseconds: UInt64 = 460_000_000

    /// Start the zoom from the icon's centre. The start frame is
    /// committed without animation so the 0.12 / 44 frame shows for one
    /// frame before the spring expands it.
    func start(from anchorPoint: UnitPoint) {
        anchor = anchorPoint
        scale = Self.zoomScale
        radius = Self.zoomRadius
        opacity = 0
        isActive = true
    }

    /// Expand to full screen (0.46 s spring-open, opacity 0.18 s).
    func expand() {
        withAnimation(.spring(response: 0.46, dampingFraction: 0.85)) {
            scale = 1.0
            radius = 0
        }
        withAnimation(.easeOut(duration: 0.18)) {
            opacity = 1.0
        }
    }

    func end() {
        isActive = false
        scale = 1.0
        opacity = 1.0
        radius = 0
    }
}

/// The expanding window drawn over the desktop during launch: a rounded
/// rect in the guest app's icon tint, anchored at the tapped icon.
struct LaunchZoomOverlay: View {
    @ObservedObject var zoom: LaunchZoomState
    var icon: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if zoom.isActive {
                    Group {
                        if let icon {
                            Image(uiImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Color(.systemBackground)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: zoom.radius, style: .continuous))
                    .scaleEffect(zoom.scale, anchor: zoom.anchor)
                    .opacity(zoom.opacity)
                    .ignoresSafeArea()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
