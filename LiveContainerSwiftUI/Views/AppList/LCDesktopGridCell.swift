//
//  LCDesktopGridCell.swift
//  LiveContainerSwiftUI
//
//  Desktop grid v1: one pure-SwiftUI icon cell (60pt icon + one-line name).
//
//  Why a new cell instead of reusing LCAppBanner:
//  LCAppBanner is a UIViewControllerRepresentable wrapping
//  LCAppBannerViewController (UIKit, context menu at line 225 of the view
//  controller, run button, double-tap to open settings, uninstall flow).
//  A banner is a full-width list row built for a vertical list; it cannot
//  live inside a LazyVGrid as a 60pt icon, it carries UIKit gesture and
//  sizing behaviour the grid must not inherit, and its update cycle is
//  driven by a view controller. The grid cell reuses only the data the
//  banner also uses: LCAppModel + appInfo.iconIsDarkIcon(_:) through the
//  existing IconImageView (corner radius = width x 0.2667, same as the
//  banner and the custom-sort list).
//

import SwiftUI

/// One desktop icon: 60pt icon tile + a single line of name below it.
/// Long names truncate with an ellipsis and shrink; they never wrap.
struct LCDesktopGridCell: View {
    let icon: LCDesktopIcon
    let isEditing: Bool
    /// True while this icon is the one being dragged (slightly enlarged,
    /// semi-transparent).
    let isDragged: Bool
    /// True while a dragged icon hovers over this cell: the cell is drawn
    /// as an empty slot so the user sees where the drop will land.
    let isDropTarget: Bool
    let darkModeIcon: Bool
    /// Desktop theme (system / dark / light). Drives the icon-name
    /// colour; the name always also gets a dark shadow, so a light
    /// theme on a dark wallpaper stays readable.
    let theme: LCDesktopTheme

    var onTap: () -> Void
    var onDelete: (() -> Void)?
    var onLongPress: () -> Void

    @State private var jiggling = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                iconTile
                    .frame(width: 60, height: 60)
                    .opacity(isDropTarget ? 0.0 : 1.0)
                    .overlay {
                        // Empty-slot hint: a dashed rounded rect where the
                        // dragged icon will land.
                        if isDropTarget {
                            RoundedRectangle(cornerRadius: 60 * 0.2667)
                                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                                .foregroundStyle(.secondary)
                                .frame(width: 60, height: 60)
                        }
                    }

                if isEditing, icon.isDeletable {
                    Button {
                        onDelete?()
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(.red))
                    }
                    .offset(x: -8, y: -8)
                }

                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(.black.opacity(0.6)))
                        .offset(x: 44, y: 44)
                }
            }

            Text(icon.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.7)
                .foregroundStyle(theme.nameColor)
                // Shadow fallback: guarantees the name stays readable
                // whatever the wallpaper + theme combination is (e.g.
                // light theme on a dark wallpaper).
                .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1)
                .frame(maxWidth: 76)
        }
        .frame(maxWidth: .infinity)
        // Lifted icon: bigger, slightly transparent, floating on a
        // shadow — the iPhone home-screen lift. Was scale 1.08 /
        // opacity 0.6 with no shadow, and the change snapped because
        // the only .animation on the cell was keyed on jiggling.
        .opacity(isDragged ? 0.85 : 1.0)
        .scaleEffect(isDragged ? 1.15 : 1.0)
        .shadow(color: isDragged ? .black.opacity(0.3) : .clear, radius: isDragged ? 12 : 0, x: 0, y: isDragged ? 8 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isDragged)
        // The hovered drop target fades to the dashed slot smoothly
        // instead of blinking out.
        .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        // Jiggle: small back-and-forth rotation, iPhone edit-mode style.
        .rotationEffect(.degrees(isEditing ? (jiggling ? 1.2 : -1.2) : 0))
        .animation(
            isEditing ? .easeInOut(duration: 0.12).repeatForever(autoreverses: true) : .default,
            value: jiggling
        )
        .onChange(of: isEditing) { editing in
            jiggling = editing
        }
        // High-priority tap: without this, a tap on an icon in edit
        // mode ALSO fires the desktop container's tap-to-exit-edit
        // gesture (SwiftUI delivers the tap to ancestor gestures too),
        // so tapping any icon would silently leave edit mode. The
        // high-priority tap claims the touch first, so in edit mode a
        // tap on an icon does nothing (as on the iPhone home screen)
        // and only a tap on blank desktop exits edit mode.
        .highPriorityGesture(
            TapGesture().onEnded {
                // Tapping does nothing in edit mode (same as the
                // iPhone home screen); launching is only available
                // outside edit mode.
                guard !isEditing else {
                    return
                }
                onTap()
            }
        )
        .onLongPressGesture(minimumDuration: 0.5) {
            onLongPress()
        }
    }

    private var isLocked: Bool {
        guard let model = icon.appModel else {
            return false
        }
        return model.appInfo.isLocked
    }

    @ViewBuilder
    private var iconTile: some View {
        switch icon {
        case .app(let model):
            IconImageView(icon: model.appInfo.iconIsDarkIcon(darkModeIcon))
        case .system(let page):
            RoundedRectangle(cornerRadius: 60 * 0.2667)
                .fill(page.tint)
                .overlay {
                    Image(systemName: page.systemImage)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
        }
    }
}

// MARK: - Hide the system Tab Bar on the Apps page

extension View {
    /// Hides the Tab Bar while the desktop is shown; the three system icons
    /// replace it as the entry to Sources / Tweaks / Settings. iOS 16+ API,
    /// so on iOS 15 this is a no-op and the Tab Bar stays (known gap, see
    /// DESKTOP_GRID_V1.md).
    func hideDesktopTabBar() -> some View {
        if #available(iOS 16.0, *) {
            return AnyView(self.toolbar(.hidden, for: .tabBar))
        } else {
            return AnyView(self)
        }
    }
}
