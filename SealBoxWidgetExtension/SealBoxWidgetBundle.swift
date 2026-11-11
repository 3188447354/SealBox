//
//  SealBoxWidgetBundle.swift
//  SealBoxWidgetExtension
//
//  The Widget Extension entry point. This extension renders ONLY the
//  container app's Live Activity (install progress / launching) on the
//  Dynamic Island and the lock screen. It contains no home-screen widgets.
//
//  iOS 16.1+ (the extension's deployment target). The main app runs on
//  iOS 15+, but Live Activities do not exist there, so the extension
//  simply never loads on iOS 15.
//

import SwiftUI
import WidgetKit

@main
struct SealBoxWidgetBundle: WidgetBundle {
    var body: some Widget {
        SealBoxLiveActivityWidget()
    }
}
