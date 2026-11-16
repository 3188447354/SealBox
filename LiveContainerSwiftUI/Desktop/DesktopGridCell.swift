//
//  DesktopGridCell.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — one desktop grid cell.
//
//  Research §1.1/§1.2/§2.2.1: 58pt icon, one-line name (12pt, truncates,
//  minimumScaleFactor 0.7, name max width 76pt, icon–name spacing 4pt),
//  corner radius = width × 0.2667 (the 22.37% HIG value disagrees —
//  0.2667 is what the shipped code used; true-device screenshot
//  comparison still has to pick one), name shadow black 0.55 / radius 2 /
//  y +1pt. Press: scale to 0.86 within 80 ms, spring back
//  (response 0.38, dampingFraction 0.6); finger moving > 9pt cancels
//  the press so a page swipe never leaves an icon squashed. Edit mode:
//  icon pops 0.88 → 1 (spring 0.34 / 0.6) then jiggles — ±1.5–1.6°,
//  three period variants (0.31 / 0.23 / 0.26 s) by id hash, one mirrored,
//  plus ±0.5px vertical drift so icons never sway in sync. Delete badge:
//  23×23 white circle + black minus, offset (2, −5), appears with a
//  0.38 s spring-pop; its hit area is padded to 44×44pt (HIG minimum).
//
//  Edit-mode tap does NOT launch (research §4 #7 — the old P2-28
//  "edit-mode tap still opens" tradeoff is reverted to native).

import Foundation
import SwiftUI

/// The icon tile shared by the grid cell, the Dock icon and the drag
/// ghost: the guest app's generated icon (never the CFBundleIcons key —
/// LCAppInfo.iconIsDarkIcon handles cache + dark variant), or a blank
/// tile when no icon image can be produced. No invented glyphs.
struct AppIconImage: View {
    let app: LCAppModel
    var size: CGFloat = 58
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Group {
            if let image = app.appInfo.iconIsDarkIcon(colorScheme == .dark) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2667, style: .continuous))
    }
}

struct DesktopGridCell: View {
    let icon: LCDesktopIcon
    let displayName: String
    var isEditing: Bool
    var isDragged: Bool
    var isDropHover: Bool
    /// Normal-mode long-press lift (item 7): the icon scales up in
    /// place while the finger holds it, before any drag starts.
    var isLifted: Bool = false
    var onDelete: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil

    @State private var isPressing = false
    @State private var jiggling = false

    /// Jiggle period: 0.31 / 0.23 / 0.26 s by id hash (research §1.2).
    private var jiggleDuration: Double {
        switch abs(icon.id.hashValue) % 3 {
        case 1: return 0.23
        case 2: return 0.26
        default: return 0.31
        }
    }

    /// Jiggle angles: −1.6°…+1.5°, every 4th icon mirrored (+1.4°…−1.6°).
    private var jiggleAngles: (from: Double, to: Double) {
        if abs(icon.id.hashValue) % 4 == 0 {
            return (from: 1.4, to: -1.6)
        }
        return (from: -1.6, to: 1.5)
    }

    var body: some View {
        Button {
            // Edit-mode tap does not launch (native behaviour).
            guard !isEditing else { return }
            onTap?()
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    if isDragged {
                        // Dragged cell becomes a dashed empty slot
                        // (2pt dash [5, 4], research §2.2.2).
                        RoundedRectangle(cornerRadius: 58 * 0.2667, style: .continuous)
                            .stroke(style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 58, height: 58)
                    } else {
                        if case .app(let model) = icon {
                            AppIconImage(app: model, size: 58)
                        } else if case .system(let page) = icon {
                            RoundedRectangle(cornerRadius: 58 * 0.2667, style: .continuous)
                                .fill(page.tint)
                                .overlay {
                                    Image(systemName: page.systemImage)
                                        .font(.system(size: 58 * 0.43, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                .frame(width: 58, height: 58)
                        }
                    }
                    if isDropHover && !isDragged {
                        RoundedRectangle(cornerRadius: 58 * 0.2667, style: .continuous)
                            .stroke(Color.white.opacity(0.85), lineWidth: 2)
                            .frame(width: 58 + 4, height: 58 + 4)
                    }
                }
                Text(displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 76)
                    .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1)
            }
        }
        .buttonStyle(DesktopCellButtonStyle(isPressing: $isPressing))
        .scaleEffect(isLifted ? LCDesktopDragState.dragLiftScale : (isEditing ? 1.0 : (isPressing ? 0.86 : 1.0)))
        .shadow(color: isLifted ? .black.opacity(0.35) : .clear, radius: isLifted ? 12 : 0, x: 0, y: 8)
        .rotationEffect(.degrees(isEditing ? (jiggling ? jiggleAngles.to : jiggleAngles.from) : 0))
        .offset(y: isEditing && jiggling ? 0.5 : 0)
        .animation(
            isEditing ? .easeInOut(duration: jiggleDuration).repeatForever(autoreverses: true) : .default,
            value: jiggling
        )
        .onChange(of: isEditing) { editing in
            // 0.0.5: set jiggling WITHOUT withAnimation. The
            // .animation(repeatForever) modifier above is what makes
            // the icon oscillate; wrapping this assignment in
            // withAnimation(.spring) put a one-shot spring transaction
            // on the change, which overrode the repeating animation —
            // the icon rotated once and then froze, so edit mode
            // showed no jiggle on device. A plain assignment lets
            // the modifier drive the jiggle; exiting edit mode sets
            // it false and the rotation returns to 0.
            jiggling = editing
        }
        .overlay(alignment: .topLeading) {
            if isEditing, icon.isDeletable, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 23, height: 23)
                        .background(Circle().fill(Color(red: 238 / 255, green: 240 / 255, blue: 245 / 255).opacity(0.96)))
                }
                // Visual 23×23, hit area padded to the 44pt HIG minimum.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .offset(x: 2 - 10.5, y: -5 - 10.5)
                .scaleEffect(isEditing ? 1 : 0)
                .animation(.spring(response: 0.38, dampingFraction: 0.6), value: isEditing)
            }
        }
    }
}

/// Press feedback: scale to 0.86 within 80 ms on press; a > 9pt move
/// cancels the press (handled by the drag gesture — the button itself
/// only tracks press state while the finger stays put).
private struct DesktopCellButtonStyle: ButtonStyle {
    @Binding var isPressing: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { pressed in
                if pressed {
                    withAnimation(.easeOut(duration: 0.08)) {
                        isPressing = true
                    }
                } else {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.6)) {
                        isPressing = false
                    }
                }
            }
    }
}
