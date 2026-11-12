//
//  LCBottomSheet.swift
//  LiveContainerSwiftUI
//
//  SealBox bottom sheet (demo §11.1): the one sheet style every
//  operation / confirmation / selection UI in SealBox uses, replacing
//  the system .sheet / .alert / .confirmationDialog presentations.
//
//  Spec (demo §11.1):
//  - Slides up from below the screen in 0.58 s spring-sheet; the
//    parent drives the entry/exit with `LCBottomSheet.transition`
//    + `.animation(LCBottomSheet.spring, value: flag)` (same pattern
//    as the Control Center overlay in LCAppListView).
//  - Corner radius 30, bottom 10, side margins 10, max height 78%.
//  - Scrim rgba(8,10,20,.28); tap scrim closes.
//  - Grabber drag-to-close: the grab pill (74x19 hit area) follows
//    the finger 1:1, scrim fades proportionally (1 − dy/320);
//    release closes if dy > 90 or (dy > 24 and v > 0.45 pt/ms),
//    otherwise springs back. (Velocity from LCVelocityTracker,
//    the shared last-6-samples tracker in LCSealBoxHomeBar.swift.)
//  - Row buttons press to scale 0.975 (LCBottomSheetButtonStyle).
//
//  What this is NOT: it never hosts a system picker. The IPA file
//  importer (UIDocumentPicker via presentFromTopmost) and the photo
//  picker (PHPickerViewController) stay system presentations —
//  restyling them would break the certificate-import race fix and
//  the picker's own navigation. Text-field alerts stay UIAlerts
//  for the same reason plus keyboard avoidance.
//

import SwiftUI

/// Bottom sheet container (demo §11.1). `onDismiss` only hides the
/// sheet; callers that must resolve an async helper (AlertHelper /
/// YesNoHelper) do so inside their `onDismiss` / button actions.
struct LCBottomSheet<Content: View>: View {
    /// Shared sheet motion: 0.58 s spring-sheet (demo §11.1).
    static let spring = Animation.spring(response: 0.58, dampingFraction: 0.8)
    /// Shared sheet transition: slide from the bottom + fade.
    static let transition = AnyTransition.asymmetric(
        insertion: .move(edge: .bottom).combined(with: .opacity),
        removal: .move(edge: .bottom).combined(with: .opacity)
    )

    var onDismiss: () -> Void
    @ViewBuilder var content: () -> Content

    /// Live drag offset while the grabber is pulled down.
    @State private var dragOffset: CGFloat = 0
    /// Scrim opacity factor while dragging (1 at rest).
    @State private var scrimOpacity: Double = 1
    @State private var velocityTracker = LCVelocityTracker()

    var body: some View {
        ZStack(alignment: .bottom) {
            // Scrim (demo §11.1): rgba(8,10,20,.28); tap closes.
            Color(red: 8 / 255, green: 10 / 255, blue: 20 / 255)
                .opacity(0.28 * scrimOpacity)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }
            VStack(spacing: 0) {
                // Grab pill: 36x5 capsule inside a 74x19 hit area.
                Capsule()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 36, height: 5)
                    .frame(width: 74, height: 19)
                    .contentShape(Rectangle())
                    .padding(.top, 8)
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                let dy = max(0, value.translation.height)
                                dragOffset = dy
                                scrimOpacity = Double(max(0, 1 - dy / 320))
                                velocityTracker.record(CGPoint(
                                    x: value.translation.width,
                                    y: value.translation.height
                                ))
                            }
                            .onEnded { value in
                                let dy = max(0, value.translation.height)
                                let v = velocityTracker.velocity.dy
                                velocityTracker.reset()
                                // Close (demo §11.1): dy > 90, or
                                // dy > 24 with downward v > 0.45.
                                if dy > 90 || (dy > 24 && v > 0.45) {
                                    onDismiss()
                                } else {
                                    withAnimation(Self.spring) {
                                        dragOffset = 0
                                        scrimOpacity = 1
                                    }
                                }
                            }
                    )
                content()
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
            // Max height 78% of the screen (demo §11.1).
            .frame(maxHeight: UIScreen.main.bounds.height * 0.78, alignment: .top)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 30))
            .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 8)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .offset(y: dragOffset)
        }
    }
}

/// Row-button press feedback (demo §11.1): scale 0.975, 0.3 s
/// spring-pop, pressed-row background rgba(255,255,255,.16).
struct LCBottomSheetButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            .background(
                configuration.isPressed
                    ? Color.white.opacity(0.16)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// One full-width action row in a bottom sheet: a centred title,
/// red when `role` is .destructive, Cancel-styled when .cancel.
struct LCBottomSheetActionRow: View {
    let title: String
    var role: ButtonRole? = nil
    var action: () -> Void

    var body: some View {
        Button(role: role) {
            action()
        } label: {
            Text(title)
                .font(.system(size: 17))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(LCBottomSheetButtonStyle())
    }
}
