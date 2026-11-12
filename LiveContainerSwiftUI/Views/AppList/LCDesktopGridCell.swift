//
//  LCDesktopGridCell.swift
//  LiveContainerSwiftUI
//
//  Desktop grid v1: one pure-SwiftUI icon cell (58pt icon + one-line name).
//
//  Why a new cell instead of reusing LCAppBanner:
//  LCAppBanner is a UIViewControllerRepresentable wrapping
//  LCAppBannerViewController (UIKit, context menu at line 225 of the view
//  controller, run button, double-tap to open settings, uninstall flow).
//  A banner is a full-width list row built for a vertical list; it cannot
//  live inside a LazyVGrid as a 58pt icon, it carries UIKit gesture and
//  sizing behaviour the grid must not inherit, and its update cycle is
//  driven by a view controller. The grid cell reuses only the data the
//  banner also uses: LCAppModel + appInfo.iconIsDarkIcon(_:) through the
//  existing IconImageView (corner radius = width x 0.2667, same as the
//  banner and the custom-sort list).
//
//  Press feedback (demo §1.2): tile scales to 0.86 within 80 ms on
//  pointer down, springs back on release; the press clears if the finger
//  moves > 9 pt (the same cancel distance as the long-press).
//  Long-press → edit mode is 450 ms (demo §1.3, see LCDesktopDragState);
//  the drag itself lives in LCDesktopDrag.swift, not in this cell.
//
//  Dragging (demo §1): the cell itself carries no drag gesture —
//  LCAppListView attaches the long-press → drag gesture (see
//  LCDesktopIconDragGesture in LCDesktopDrag.swift). While an icon is
//  being dragged, its cell is drawn as an empty dashed slot (the ghost
//  icon floats above it); the hovered drop target keeps its icon and
//  gets the demo's 2 pt white outline (a drop swaps with that one cell).
//

import SwiftUI

/// One desktop icon: 58pt icon tile + a single line of name below it.
/// Long names truncate with an ellipsis and shrink; they never wrap.
struct LCDesktopGridCell: View {
    let icon: LCDesktopIcon
    let isEditing: Bool
    /// True while this icon is the one being dragged: the cell is drawn
    /// as an empty slot (the ghost icon is the dragged tile).
    let isDragged: Bool
    /// True while a dragged icon hovers over this cell: the cell keeps
    /// its icon and gets the demo's drop outline (a drop swaps with it).
    let isDropTarget: Bool
    let darkModeIcon: Bool
    /// Desktop theme (system / dark / light). Drives the icon-name
    /// colour; the name always also gets a dark shadow, so a light
    /// theme on a dark wallpaper stays readable.
    let theme: LCDesktopTheme

    var onTap: () -> Void
    var onDelete: (() -> Void)?

    @State private var jiggling = false
    /// Set when the delete badge was just tapped. The cell's tap
    /// gesture sits on an ancestor of the badge, so a badge tap
    /// fires both the button and the tap gesture on the same
    /// touch-up; the tap defers one runloop and stands down when
    /// this flag is set, so tapping "−" never also opens the app
    /// (P2-28: edit-mode taps now open apps).
    @State private var badgeJustTapped = false
    /// Edit-entry pop (demo §1.3): icons scale 0.88 → 1 once, 0.34 s
    /// spring-pop, when edit mode is entered.
    @State private var editPopScale: CGFloat = 1.0
    /// Press feedback (demo §1.2): tile scales to 0.86 within 80 ms.
    @State private var isPressing = false

    /// Jiggle phase, per icon (demo §2.2): the icons must not rock in
    /// unison. Derived from the icon id so it is stable per icon:
    /// durations 0.31 / 0.23 / 0.26 s, one variant mirrored.
    private var jiggleDuration: Double {
        switch abs(icon.id.hashValue) % 3 {
        case 0: return 0.31
        case 1: return 0.23
        default: return 0.26
        }
    }

    /// Jiggle angles (demo §2.2): −1.6°…+1.5°, mirrored (+1.4°…−1.6°)
    /// for every fourth icon.
    private var jiggleAngles: (from: Double, to: Double) {
        abs(icon.id.hashValue) % 4 == 0 ? (1.4, -1.6) : (-1.6, 1.5)
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                LCDesktopIconTile(icon: icon, darkModeIcon: darkModeIcon, size: 58)
                    .opacity(isDragged ? 0.0 : 1.0)
                    .overlay {
                        // Empty origin slot: the dragged icon's cell
                        // shows a dashed rounded rect while the ghost
                        // floats above it.
                        if isDragged {
                            RoundedRectangle(cornerRadius: 58 * 0.2667)
                                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                                .foregroundStyle(.secondary)
                                .frame(width: 58, height: 58)
                        }
                        // Drop-target highlight (demo §1.4): the
                        // hovered cell keeps its icon and gets a 2 pt
                        // white outline, offset 2 pt.
                        if isDropTarget {
                            RoundedRectangle(cornerRadius: 58 * 0.2667)
                                .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                                .padding(-2)
                                .frame(width: 58, height: 58)
                        }
                    }
                    // The tile fading out (dragged) and the highlight
                    // appearing (drop target) ease over 0.15 s.
                    .animation(.easeInOut(duration: 0.15), value: isDragged)
                    .animation(.easeInOut(duration: 0.15), value: isDropTarget)
                    // Press feedback (demo §1.2): 0.86 within 80 ms on
                    // press, spring-pop back on release. A simultaneous
                    // zero-distance drag only records press state — it
                    // never steals the caller's long-press → drag
                    // gesture or the tap. The press clears once the
                    // finger moves > 9 pt, so a page swipe starting on
                    // an icon does not leave it shrunk.
                    .scaleEffect(isPressing ? 0.86 : 1.0)
                    .animation(
                        isPressing ? .easeOut(duration: 0.08) : .spring(response: 0.38, dampingFraction: 0.6),
                        value: isPressing
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if hypot(value.translation.width, value.translation.height) > 9 {
                                    isPressing = false
                                } else {
                                    isPressing = true
                                }
                            }
                            .onEnded { _ in
                                isPressing = false
                            }
                    )

                if isEditing, icon.isDeletable {
                    Button {
                        badgeJustTapped = true
                        onDelete?()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            badgeJustTapped = false
                        }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 23, height: 23)
                            .background(Circle().fill(Color(red: 238 / 255, green: 240 / 255, blue: 245 / 255).opacity(0.96)))
                    }
                    .offset(x: 2, y: -5)
                    // Badge-in (demo §2.2): 0.38 s spring-pop, scale 0 → 1.
                    .transition(.scale.combined(with: .opacity))
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
        // The dragged cell is an empty slot (see above); the lift
        // (1.15× + shadow) lives on the ghost icon, not the cell.
        // Edit-entry pop: 0.88 → 1 once on entering edit mode.
        .scaleEffect(editPopScale)
        // Jiggle (demo §2.2): ±1.5–1.6° with ±0.5 px vertical shift,
        // phase/speed varying per icon so they don't rock in unison.
        .rotationEffect(.degrees(isEditing ? (jiggling ? jiggleAngles.to : jiggleAngles.from) : 0))
        .offset(y: isEditing ? (jiggling ? 0.5 : -0.5) : 0)
        .animation(
            isEditing ? .easeInOut(duration: jiggleDuration).repeatForever(autoreverses: true) : .default,
            value: jiggling
        )
        .onChange(of: isEditing) { editing in
            if editing {
                // Start the jiggle from the `from` angle: the angle
                // is `from` while jiggling is false, so flip the phase
                // on the next runloop — the repeatForever animation
                // then oscillates `from` ↔ `to`. Flipping it in this
                // same transaction would interpolate from 0 (the
                // non-editing angle) instead, a one-sided wobble.
                jiggling = false
                DispatchQueue.main.async {
                    jiggling = true
                }
                // Entry pop: start at 0.88 (instant — the isEditing
                // animation below must not ease this leg) and spring
                // to 1 over 0.34 s.
                withAnimation(nil) {
                    editPopScale = 0.88
                }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.6)) {
                    editPopScale = 1.0
                }
            } else {
                jiggling = false
                editPopScale = 1.0
            }
        }
        // The delete badge's scale/opacity transition (badge-in) is
        // driven by the edit-mode change.
        .animation(.spring(response: 0.38, dampingFraction: 0.6), value: isEditing)
        // High-priority tap: without this, a tap on an icon in edit
        // mode ALSO fires the desktop container's tap-to-exit-edit
        // gesture (SwiftUI delivers the tap to ancestor gestures too),
        // so tapping any icon would silently leave edit mode. The
        // high-priority tap claims the touch first.
        // Edit-mode taps open the app (demo §2.5 / P2-28: opening
        // exits edit mode, in desktopIconTapped) instead of doing
        // nothing as before. The tap is deferred one runloop: a tap
        // on the delete badge fires this gesture on the same
        // touch-up as the badge button, and by the next runloop the
        // button has set badgeJustTapped, so the badge tap stands
        // down here and never opens the app.
        .highPriorityGesture(
            TapGesture().onEnded {
                DispatchQueue.main.async {
                    if badgeJustTapped {
                        badgeJustTapped = false
                        return
                    }
                    onTap()
                }
            }
        )
        // Frame reporting for the drag hit-test: the cell's rect in
        // the "desktop" coordinate space.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LCDesktopCellFramePreferenceKey.self,
                    value: [icon.id: proxy.frame(in: .named("desktop"))]
                )
            }
        )
    }

    private var isLocked: Bool {
        guard let model = icon.appModel else {
            return false
        }
        return model.appInfo.isLocked
    }
}

/// An empty grid slot (demo §1.5): a slot with no app. It stays empty —
/// nothing auto-fills it. While a drag hovers it, it shows the drop
/// outline; dropping there moves the dragged icon to exactly this slot.
/// Same footprint as a grid cell (58 pt tile + one-line label) so the
/// grid rows line up.
struct LCDesktopEmptySlotView: View {
    let isDropTarget: Bool

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 58 * 0.2667)
                .fill(Color.clear)
                .frame(width: 58, height: 58)
                .overlay {
                    // Drop-target highlight (demo §1.4): the hovered
                    // empty cell gets the same 2 pt white outline as
                    // an occupied one.
                    if isDropTarget {
                        RoundedRectangle(cornerRadius: 58 * 0.2667)
                            .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                            .padding(-2)
                            .frame(width: 58, height: 58)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: isDropTarget)
            // Blank label line: keeps the slot exactly as tall as a
            // grid cell so empty rows do not collapse.
            Text(" ")
                .font(.system(size: 12))
                .frame(maxWidth: 76)
        }
        .frame(maxWidth: .infinity)
    }
}
