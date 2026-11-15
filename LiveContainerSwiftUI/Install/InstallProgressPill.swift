//
//  InstallProgressPill.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — top floating install pill.
//
//  Research §3 step 4: a small pill at the top of the desktop, spinner
//  + percentage in tabular digits, .ultraThinMaterial capsule, 14pt
//  horizontal / 8pt vertical padding, 12pt from the top. The install
//  total is 100 units: decompress 80 / sign 20 (InstallFlow). A remote
//  download reports before that as "正在下载" with a spinner and no
//  percentage (its length is not part of the 80/20 weights). The pill
//  fades out within 0.5 s after the icon lands; it never overlaps the
//  landing animation.

import Foundation
import SwiftUI

struct InstallProgressPill: View {
    @ObservedObject var installFlow: InstallFlow

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
            if installFlow.isDownloading {
                Text("lc.appList.downloading".loc)
                    .font(.footnote)
            } else {
                Text("\(Int(installFlow.progressFraction * 100))%")
                    .font(.footnote)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
        .padding(.top, 12)
    }
}
