//
//  LCContainerLiveActivity.swift
//  LiveContainerSwiftUI
//
//  Desktop grid v1: a minimal ActivityKit Live Activity for the CONTAINER
//  app itself. Two events only: IPA install progress and guest-app
//  launching.
//
//  What this file is and is NOT:
//  - It defines the request / update / end lifecycle. The Attributes
//    definition itself lives in LCContainerLiveActivityAttributes.swift
//    (same folder), which is duplicated verbatim into the Widget
//    Extension target — see the KEEP IN SYNC header there.
//  - It does NOT render anything on the Dynamic Island by itself. A Live
//    Activity is requested from the app via ActivityKit but RENDERED BY
//    THE WIDGET EXTENSION: SealBoxWidgetExtension provides the
//    ActivityConfiguration (Dynamic Island + lock screen UI) for
//    LCContainerLiveActivityAttributes. No lock screen widget and no push
//    updates are included (minimal version).
//  - Guest apps' own Live Activities CANNOT be done: a guest app is never
//    installed in the system, so the system only recognises the container
//    app's single Bundle ID. Only the container's own activities exist.
//
//  Info.plist: NSSupportsLiveActivities = YES was added to
//  LiveContainer/Info.plist (main app target). No new entitlement is
//  needed for Live Activities: ActivityKit needs no entitlement, and the
//  main app entitlements file was verified to need no change.
//
//  Timing (Seal pairing-island lesson): finishing does NOT end the
//  activity immediately. finish() first updates to a finished state and
//  keeps it visible for ~8 seconds, then ends it; ending at once makes
//  the system pull the activity off the island immediately, so the user
//  would never see the "done" state.
//  iOS 16.1+ only; every call site is guarded with `if #available(iOS 16.1, *)`.
//

import ActivityKit
import Foundation

@available(iOS 16.1, *)
public enum LCContainerLiveActivityManager {
    /// How long the finished state stays on the island before ending.
    private static let finishedVisibleDuration: Duration = .seconds(8)

    @MainActor
    private static var currentActivity: Activity<LCContainerLiveActivityAttributes>?

    /// Request a new activity, ending any previous one first. Only one
    /// container activity runs at a time.
    public static func start(appName: String, kind: LCContainerLiveActivityAttributes.Kind) {
        Task { @MainActor in
            await endNow()
            let attributes = LCContainerLiveActivityAttributes(appName: appName, kind: kind)
            let initialState = LCContainerLiveActivityAttributes.ContentState(
                progress: 0,
                statusText: initialStatusText(for: kind)
            )
            do {
                currentActivity = try Activity.request(
                    attributes: attributes,
                    content: .init(state: initialState, staleDate: nil),
                    pushType: nil
                )
            } catch {
                // Live Activities can fail (e.g. user disabled them, or
                // the system is out of budget). The install / launch
                // itself must never fail because of this.
                print("LCContainerLiveActivity: request failed: \(error)")
                currentActivity = nil
            }
        }
    }

    public static func startInstall(appName: String) {
        start(appName: appName, kind: .install)
    }

    public static func startLaunching(appName: String) {
        start(appName: appName, kind: .launching)
    }

    /// Update progress (0...1) and status text while the work runs.
    public static func updateProgress(_ progress: Double, statusText: String) {
        Task { @MainActor in
            guard let activity = currentActivity else {
                return
            }
            let state = LCContainerLiveActivityAttributes.ContentState(
                progress: min(1.0, max(0.0, progress)),
                statusText: statusText
            )
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    /// Mark finished, keep the finished state visible for a while, then
    /// end. Never ends immediately: see the header comment.
    public static func finish(statusText: String) {
        Task { @MainActor in
            guard let activity = currentActivity else {
                return
            }
            let state = LCContainerLiveActivityAttributes.ContentState(
                progress: 1.0,
                statusText: statusText,
                isFinished: true
            )
            await activity.update(.init(state: state, staleDate: nil))
            try? await Task.sleep(for: finishedVisibleDuration)
            await activity.end(nil, dismissalPolicy: .default)
            if currentActivity?.id == activity.id {
                currentActivity = nil
            }
        }
    }

    /// End at once, without a finished state. Used on error / cancel paths.
    @MainActor
    public static func endNow() async {
        guard let activity = currentActivity else {
            return
        }
        currentActivity = nil
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    private static func initialStatusText(for kind: LCContainerLiveActivityAttributes.Kind) -> String {
        switch kind {
        case .install:
            return "lc.appList.installation".loc
        case .launching:
            return "lc.appBanner.waitForJitTitle".loc
        }
    }
}
