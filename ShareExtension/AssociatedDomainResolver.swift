//
//  AssociatedDomainResolver.swift
//  ShareExtension
//
//  SealBox 0.0.3 rebuild — direct-IPA link resolution only
//  (implementation #2).
//
//  What this file used to do — fetch apple-app-site-association files
//  to match a shared link to a guest app ("Open in App") — is gone
//  with the Open-in-App UI. What remains is the one question the new
//  install flow needs: is this shared link a DIRECT .ipa link?
//
//  - The URL itself ends in .ipa / .tipa → it is direct.
//  - Otherwise one HEAD request follows the redirects; the final URL
//    ends in .ipa / .tipa → it is direct.
//  - Anything else → nil (the caller shows "不是 IPA 直链").
//  There is no SideStore branch here (and none in the old file either
//  — the SideStore code lived in the deleted ViewModel's built-in
//  SideStore launch path, not in this resolver).

import Foundation

enum AssociatedDomainResolver {
    /// Returns the direct .ipa / .tipa URL for a shared link, or nil.
    static func directIPALink(from url: URL) async -> URL? {
        if isDirectIPALink(url) {
            return url
        }
        // Follow redirects once and re-check the landing URL.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let finalURL = response.url, isDirectIPALink(finalURL) else {
                return nil
            }
            return finalURL
        } catch {
            return nil
        }
    }

    static func isDirectIPALink(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "ipa" || ext == "tipa"
    }
}
