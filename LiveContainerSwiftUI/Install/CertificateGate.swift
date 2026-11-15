//
//  CertificateGate.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — the certificate gate.
//
//  The bootstrap hard gate (LCBootstrap.m:256) refuses to start any guest
//  app on iOS 26+ without an imported certificate, and JIT-less signing
//  cannot work without one on any version — so a launch would die
//  silently inside runApp. Check the same value the bootstrap checks
//  (LCSharedUtils.certificatePassword(), i.e. the "LCCertificatePassword"
//  app-group key the Settings import writes) BEFORE any launch animation,
//  and prompt instead of launching. A launch that still fails with the
//  bootstrap's no-certificate error (e.g. the certificate was removed
//  after the pre-check) hits the same guide via isMissingCertificateError.

import Foundation
import SwiftUI

/// The bootstrap's own check, mirrored in Swift.
var hasImportedCertificate: Bool {
    LCSharedUtils.certificatePassword() != nil
}

/// Whether a launch failure is the bootstrap's no-certificate JIT-less
/// refusal (LCBootstrap.m:259). Matched on substrings, not equality:
/// runApp rethrows the bootstrap string verbatim, but its exact wording
/// is bootstrap-owned and may gain a prefix/suffix. The two fragments
/// are the stable core of that string.
func isMissingCertificateError(_ error: Error) -> Bool {
    let message = error.localizedDescription
    return message.contains("JITLess mode is required")
        || message.contains("Import Certificate")
}

/// First-launch certificate guide. Shown by RootView instead of the
/// desktop until a certificate is imported; also shown as a sheet from
/// the desktop when a launch is blocked by the gate.
///
/// The actual p12 import UI lives in the Settings page (implementation
/// #2, file 23): the "Go to Settings" button asks the root to open it
/// via SharedModel.requestedSystemPage. Until that page lands, the
/// button still records the request and the guide explains where the
/// import happens — it never pretends the import happened.
struct CertificateGateView: View {
    @EnvironmentObject var sharedModel: SharedModel
    var onCertificateImported: (() -> Void)? = nil
    @State private var settingsRequested = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("lc.certificateGate.title".loc)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("lc.certificateGate.body".loc)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    sharedModel.requestedSystemPage = .settings
                    settingsRequested = true
                } label: {
                    Text("lc.certificateGate.goImport".loc)
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                if settingsRequested {
                    Text("lc.certificateGate.settingsPending".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("lc.certificateGate.checkAgain".loc) {
                    if hasImportedCertificate {
                        onCertificateImported?()
                        NotificationCenter.default.post(name: Notification.Name("SealBoxCertificateImported"), object: nil)
                    }
                }
            }
            .padding(.horizontal, 32)
        }
    }
}
