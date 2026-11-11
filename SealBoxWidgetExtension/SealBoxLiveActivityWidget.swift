//
//  SealBoxLiveActivityWidget.swift
//  SealBoxWidgetExtension
//
//  Renders the container app's Live Activity — the other half of
//  LCContainerLiveActivityManager (LiveContainerSwiftUI). The app requests
//  the activity; this widget draws it on the Dynamic Island (expanded /
//  compact / minimal) and as a lock-screen banner.
//
//  Content by kind:
//  - .install: determinate progress bar + percentage + app name.
//  - .launching: no meaningful progress exists (the manager only ever
//    reports progress 0 for a launch), so an indeterminate spinner is
//    shown instead of a bar.
//  - finished (isFinished, progress 1.0): checkmark + finished status
//    text, kept visible ~8 seconds by the manager before it ends the
//    activity.
//
//  All strings (app name, status text) arrive from the app side already
//  localised — the extension bundle has no Localizable strings of its own
//  and must not try to localise them here.
//
//  No push updates: Live Activity content updates come only from the app
//  process via ActivityKit. Remote push updates would need Apple Push
//  Notification service configuration and are intentionally not included.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct SealBoxLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LCContainerLiveActivityAttributes.self) { context in
            // Lock screen banner.
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.appName)
                        .font(.caption)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    trailingView(context: context)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.statusText)
                        .font(.caption)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    bottomView(context: context)
                }
            } compactLeading: {
                compactLeadingView(context: context)
            } compactTrailing: {
                compactTrailingView(context: context)
            } minimal: {
                minimalView(context: context)
            }
        }
    }

    // MARK: - Lock screen

    private func lockScreenView(context: ActivityViewContext<LCContainerLiveActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if context.state.isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(context.attributes.appName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if context.attributes.kind == .install {
                    Text(percentText(progress: context.state.progress))
                        .font(.subheadline)
                        .monospacedDigit()
                }
            }
            Text(context.state.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            progressView(context: context)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Dynamic Island: expanded

    private func trailingView(context: ActivityViewContext<LCContainerLiveActivityAttributes>) -> some View {
        Group {
            if context.state.isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if context.attributes.kind == .install {
                Text(percentText(progress: context.state.progress))
                    .font(.caption)
                    .monospacedDigit()
            } else {
                ProgressView()
            }
        }
    }

    private func bottomView(context: ActivityViewContext<LCContainerLiveActivityAttributes>) -> some View {
        progressView(context: context)
    }

    // MARK: - Dynamic Island: compact / minimal

    private func compactLeadingView(context: ActivityViewContext<LCContainerLiveActivityAttributes>) -> some View {
        Group {
            if context.state.isFinished {
                Image(systemName: "checkmark")
                    .font(.caption)
            } else if context.attributes.kind == .install {
                Text(percentText(progress: context.state.progress))
                    .font(.caption)
                    .monospacedDigit()
            } else {
                ProgressView()
            }
        }
    }

    private func compactTrailingView(context: ActivityViewContext<LCContainerLiveActivityAttributes>) -> some View {
        Image(systemName: "shippingbox.fill")
            .font(.caption)
    }

    private func minimalView(context: ActivityViewContext<LCContainerLiveActivityAttributes>) -> some View {
        Group {
            if context.state.isFinished {
                Image(systemName: "checkmark")
                    .font(.caption)
            } else {
                ProgressView(value: context.state.progress)
                    .progressViewStyle(.circular)
            }
        }
    }

    // MARK: - Shared pieces

    /// Determinate bar for installs, indeterminate spinner for launches,
    /// full bar once finished.
    private func progressView(context: ActivityViewContext<LCContainerLiveActivityAttributes>) -> some View {
        Group {
            if context.attributes.kind == .install || context.state.isFinished {
                ProgressView(value: context.state.progress)
            } else {
                ProgressView()
            }
        }
    }

    private func percentText(progress: Double) -> String {
        let clamped = min(1.0, max(0.0, progress))
        return "\(Int((clamped * 100).rounded()))%"
    }
}
