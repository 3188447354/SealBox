//
//  LCContainerLiveActivityAttributes.swift
//  LiveContainerSwiftUI
//
//  The ActivityAttributes + ContentState for the CONTAINER app's own Live
//  Activity (IPA install progress and guest-app launching).
//
//  KEEP IN SYNC — this file is duplicated VERBATIM in
//  SealBoxWidgetExtension/LCContainerLiveActivityAttributes.swift.
//  The two copies must stay byte-identical: the app requests the activity
//  with this type (compiled into the LiveContainerSwiftUI framework) and
//  the Widget Extension renders it with its own copy of the same type.
//  Apple documents this sharing method: the attributes definition file is
//  a member of both the app target and the widget extension target, and the
//  system matches the activity to the widget by the attributes type name
//  and its Codable layout. If you change a field here, change it in both
//  files and re-run the byte-diff check (see SEALBOX_LIVE_ACTIVITY.md).
//
//  iOS 16.1+ only.
//

import ActivityKit
import Foundation

@available(iOS 16.1, *)
public struct LCContainerLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// 0...1. 1.0 means done; also see isFinished.
        public var progress: Double
        /// One-line status, e.g. "Installing…" / "Launching…" / "Installed".
        public var statusText: String
        /// True once the work is done (progress is 1.0). The activity is
        /// kept for a few seconds in this state before ending.
        public var isFinished: Bool

        public init(progress: Double, statusText: String, isFinished: Bool = false) {
            self.progress = progress
            self.statusText = statusText
            self.isFinished = isFinished
        }
    }

    public enum Kind: String, Codable, Hashable {
        /// IPA install progress.
        case install
        /// A guest app is being launched.
        case launching
    }

    /// Name of the guest app being installed / launched.
    public var appName: String
    public var kind: Kind

    public init(appName: String, kind: Kind) {
        self.appName = appName
        self.kind = kind
    }
}
