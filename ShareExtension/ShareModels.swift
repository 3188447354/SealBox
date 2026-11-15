//
//  ShareModels.swift
//  ShareExtension
//
//  SealBox 0.0.3 rebuild — share-extension models (implementation #2).
//
//  The share extension does ONE thing now: take a shared .ipa and hand
//  it to the host for install (research §3 step 1, entry B). The old
//  "Open in App" machinery is gone with it: no guest-app list, no
//  container picker, no per-app launch, no built-in SideStore entry.
//  What remains is the payload loader, the staged-file record, and the
//  error type.
//
//  NOTE: this target has no `.loc` string extension (that lives in the
//  LiveContainerSwiftUI target, and the old share code's use of it
//  never compiled). All user-facing strings here are plain literals.

import Combine
import Foundation
import UniformTypeIdentifiers

/// What the share sheet handed us.
final class SharePayload: ObservableObject {
    enum Kind {
        case loading
        /// A local .ipa / .tipa file URL.
        case file(URL)
        /// A remote direct .ipa / .tipa link (verified by
        /// AssociatedDomainResolver).
        case remoteIPA(URL)
        case empty
        case failed(String)
    }

    @Published var kind: Kind = .loading

    static func load(from context: NSExtensionContext?) async throws -> Kind {
        guard let items = context?.inputItems as? [NSExtensionItem] else {
            return .empty
        }

        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers {
            for typeIdentifier in [UTType.url.identifier, UTType.fileURL.identifier] {
                guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
                    continue
                }
                let item = try await provider.loadItem(forTypeIdentifier: typeIdentifier)
                if let url = Self.url(from: item) {
                    return try await Self.classify(url: url)
                }
            }
        }
        return .empty
    }

    private static func url(from item: Any?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8),
           let url = URL(string: string) {
            return url
        }
        if let string = item as? String, let url = URL(string: string) {
            return url
        }
        return nil
    }

    private static func classify(url: URL) async throws -> Kind {
        if url.isFileURL {
            let ext = url.pathExtension.lowercased()
            guard ext == "ipa" || ext == "tipa" else {
                return .failed("只支持 .ipa / .tipa 文件。")
            }
            return .file(url)
        }
        // Remote link: only a direct IPA link is accepted.
        if let direct = await AssociatedDomainResolver.directIPALink(from: url) {
            return .remoteIPA(direct)
        }
        return .failed("这个链接不是 IPA 直链，无法安装。")
    }
}

/// A .ipa staged into the App Group shared directory, ready for the
/// host to pick up. The host deletes the staged file after a
/// successful install and clears the marker keys (see InstallFlow).
struct StagedIPA {
    let stagedURL: URL
    let originalName: String
    let size: Int64
}

/// Marker keys in the App Group defaults, written when a file is
/// staged and cleared by the host after install. They exist so a
/// staged file is never anonymous litter: the host knows where it
/// came from and when.
enum ShareInboxKeys {
    static let fileName = "LCShareInboxFileName"
    static let originalName = "LCShareInboxOriginalName"
    static let date = "LCShareInboxDate"
}

struct ShareExtensionError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
