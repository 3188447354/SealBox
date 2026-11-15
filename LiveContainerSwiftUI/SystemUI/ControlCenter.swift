//
//  ControlCenter.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — control center shell + JIT tile, and the
//  notification-center placeholder (system UI, implementation #2).
//
//  Research §1.7 / §3 step 11. The host app cannot show real system
//  toggles (no Wi-Fi / brightness switch can do anything real inside a
//  sideloaded host), so v1 shows exactly ONE tile: JIT. Everything
//  else is honest absence, not a fake control.
//
//  - Trigger: drag down from the top-right corner (native gesture
//    zone). Slides in as a spring sheet, response 0.58 / damping 0.8.
//  - Tile: 44×44 icon + title + subtitle "完整 JIT · 由 Seal 开启" /
//    "已关闭". Tapping the tile does nothing: JIT is opened by Seal,
//    never from inside SealBox.
//  - NO 44 pt narrow trigger strip at the top (deleted by an earlier
//    decision, stays deleted).
//  - Notification center is NOT built in v1: a drag down from the top
//    left / centre gives a light bounce and, the first time only, a
//    toast "通知中心 v1 未提供". It never shows fake notifications.
//
//  JIT state is a LIVE probe, not a stored preference: it mirrors
//  LCBootstrap.m's checkJITEnabled (LCIgnoreJITOnLaunch switch,
//  jailbreak shortcut, then the CS_DEBUGGED code-sign flag via csops).
//  The same probe is used by the Settings JIT section.

import Foundation
import SwiftUI
import Darwin

// MARK: - Live JIT probe (mirrors LCBootstrap.m checkJITEnabled)

/// CS_DEBUGGED, as defined in LiveContainer/utils.h (0x10000000).
private let csDebuggedFlag: Int32 = 0x10000000

/// Whether JIT is enabled in this process right now: a debugger (or an
/// equivalent JIT enabler opened by Seal) is attached, or the device is
/// jailbroken. This is a live check, not a stored setting — it can
/// change between launches.
func isJITEnabledNow() -> Bool {
    if UserDefaults.standard.bool(forKey: "LCIgnoreJITOnLaunch") {
        return false
    }
    // Jailbroken devices have no debugger restriction.
    if FileManager.default.isReadableFile(atPath: "/usr/lib/systemhook.dylib") {
        return true
    }
    var flags: Int32 = 0
    // ops 0 = CS_OPS_STATUS: returns the code-sign flags.
    let result = csops(getpid(), 0, &flags, MemoryLayout<Int32>.size)
    guard result == 0 else { return false }
    return (flags & csDebuggedFlag) != 0
}

// MARK: - Control center panel

struct ControlCenterView: View {
    @Binding var isPresented: Bool
    /// Live JIT state, probed by the parent when the panel opens.
    var jitEnabled: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // Tap outside: dismiss.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("控制中心")
                        .font(.headline)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color(.tertiarySystemBackground)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭控制中心")
                }

                // The only tile in v1: JIT status. It is display-only —
                // JIT is opened by Seal, never toggled here.
                HStack(spacing: 12) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(jitEnabled ? .yellow : .secondary)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.tertiarySystemBackground)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("JIT")
                            .font(.headline)
                        Text(jitEnabled ? "完整 JIT · 由 Seal 开启" : "已关闭")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(jitEnabled ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground)))

                Text("JIT 由 Seal 开启，不在 SealBox 内切换。普通应用走 JIT-less 重签，不需要 JIT。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            // No .animation(..., value:) here: the parent drives the
            // present/dismiss animation with withAnimation, and a
            // Binding is not an Equatable animation value.
        }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.58, dampingFraction: 0.8)) {
            isPresented = false
        }
    }
}

// MARK: - Notification-center placeholder (v1: bounce + first toast)

/// State for the "notification centre is not in v1" nudge. The parent
/// owns one instance and calls `nudge()` on a top left/centre pull-down.
final class NotificationCenterNudgeState: ObservableObject {
    static let toastShownKey = "LCNotificationCenterToastShown"

    @Published var toast: String?
    @Published var bounceOffset: CGFloat = 0

    private var toastTask: Task<Void, Never>?

    var toastShownBefore: Bool {
        UserDefaults.standard.bool(forKey: Self.toastShownKey)
    }

    /// Light bounce (the page follows the finger a little and springs
    /// back) plus, the first time only, the toast. Never a fake
    /// notification, never silence.
    func nudge() {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
            bounceOffset = 12
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                bounceOffset = 0
            }
        }
        guard !toastShownBefore else { return }
        UserDefaults.standard.set(true, forKey: Self.toastShownKey)
        toast = "通知中心 v1 未提供"
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(.easeOut(duration: 0.3)) {
                toast = nil
            }
        }
    }
}

/// The transient toast banner the nudge shows (top centre).
struct NotificationCenterToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.ultraThinMaterial))
            .padding(.top, 12)
    }
}
