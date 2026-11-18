// SBIPAParser.swift — 把 IPA 解压到临时目录，读 Info.plist 与图标，产出待安装的解析结果。

import Foundation

/// IPA 解析结果：安装管线（`SBInstaller`）的输入。
public struct SBParsedIPA {

    /// 客 App 的 Bundle ID（`CFBundleIdentifier`）。
    public let bundleID: String
    /// 桌面显示名（`CFBundleDisplayName` → `CFBundleName` → `CFBundleExecutable`）。
    public let displayName: String
    /// 版本（`CFBundleShortVersionString`，无则 `CFBundleVersion`）。
    public let version: String
    /// 可执行文件名（`CFBundleExecutable`）。
    public let executableName: String
    /// 临时目录内的 .app 路径（`SBInstaller.install` 会把它拷走并清理临时目录）。
    public let appURL: URL
    /// 图标数据（读出即为 PNG 内容；没有则为 nil，安装时用默认图标）。
    public let iconData: Data?
    /// 原始 IPA 文件名（Documents/IPAs 下的存档名，重装时找回源文件用）。
    public let sourceIPAFileName: String?

    public init(
        bundleID: String,
        displayName: String,
        version: String,
        executableName: String,
        appURL: URL,
        iconData: Data?,
        sourceIPAFileName: String? = nil
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.version = version
        self.executableName = executableName
        self.appURL = appURL
        self.iconData = iconData
        self.sourceIPAFileName = sourceIPAFileName
    }
}

/// IPA 解析器：解压、找 .app、读 Info.plist、读图标。
public enum SBIPAParser {

    /// 解析一个 IPA 文件。
    /// - Parameter ipaURL: .ipa / .tipa 文件 URL（可来自文件选择器或分享入口）。
    /// - Returns: 解析结果，其中 `appURL` 指向临时目录内的 .app。
    /// - Throws:
    ///   - `SBError.notAnIPA`：扩展名不是 .ipa / .tipa；
    ///   - `SBError.unzipFailed`：解压失败；
    ///   - `SBError.noAppBundle`：解压后找不到 .app；
    ///   - `SBError.infoPlistUnreadable`：Info.plist 读不到或不是字典；
    ///   - `SBError.noBundleID`：取不到 `CFBundleIdentifier`。
    /// 解析失败时已创建的临时目录会被清理，不留残留。
    public static func parse(ipaURL: URL) throws -> SBParsedIPA {
        guard ["ipa", "tipa"].contains(ipaURL.pathExtension.lowercased()) else {
            throw SBError.notAnIPA
        }

        let fileManager = FileManager.default
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("SBIPAParser-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        } catch {
            throw SBError.unzipFailed(underlying: "创建临时目录失败：\(error.localizedDescription)")
        }

        // 来自文件选择器 / 分享入口的 URL 可能是安全作用域 URL；能取则取，
        // 取不到（例如 asCopy 的临时副本）也不影响后续流程。
        let needsScopedAccess = ipaURL.startAccessingSecurityScopedResource()
        defer {
            if needsScopedAccess {
                ipaURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let unzipResult = sb_unzip_to(ipaURL.path, stagingRoot.path, nil)
            guard unzipResult == SB_UNZIP_OK else {
                throw SBError.unzipFailed(underlying: "解压 IPA 失败（错误码 \(unzipResult)）")
            }

            guard let appURL = findAppBundle(in: stagingRoot) else {
                throw SBError.noAppBundle
            }

            let plistURL = appURL.appendingPathComponent("Info.plist")
            guard let plistData = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(
                    from: plistData, options: [], format: nil
                  ) as? [String: Any] else {
                throw SBError.infoPlistUnreadable
            }

            guard let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
                throw SBError.noBundleID
            }

            // 可执行名：CFBundleExecutable，无则用 Bundle ID 最后一段兜底（设计 §2.2）。
            let executableName = (plist["CFBundleExecutable"] as? String)
                ?? bundleID.components(separatedBy: ".").last
                ?? bundleID

            // 显示名三 fallback；三者都没有时用 Bundle ID 兜底，保证桌面总有名字可显示。
            let displayName = (plist["CFBundleDisplayName"] as? String)
                ?? (plist["CFBundleName"] as? String)
                ?? (plist["CFBundleExecutable"] as? String)
                ?? bundleID

            // 版本：短版本优先，无则取构建版本，两者都没有时用 "1.0" 兜底。
            let version = (plist["CFBundleShortVersionString"] as? String)
                ?? (plist["CFBundleVersion"] as? String)
                ?? "1.0"

            let iconData = readIconData(appURL: appURL, plist: plist)

            return SBParsedIPA(
                bundleID: bundleID,
                displayName: displayName,
                version: version,
                executableName: executableName,
                appURL: appURL,
                iconData: iconData,
                sourceIPAFileName: ipaURL.lastPathComponent
            )
        } catch {
            // 解析失败：清掉本次创建的临时目录，不留半截文件。
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }
    }

    /// 在解压目录里找第一个 .app：优先取 Payload/ 下的，Payload 里没有则全目录搜。
    private static func findAppBundle(in root: URL) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var candidates: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "app" else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            candidates.append(url)
        }
        // 路径排序保证结果稳定；Payload/ 下的优先。
        candidates.sort { $0.path < $1.path }
        if let payloadApp = candidates.first(where: { $0.path.contains("/Payload/") }) {
            return payloadApp
        }
        return candidates.first
    }

    /// 读图标：`CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconFiles` 的末项优先，
    /// 没有则试 `AppIcon60x60@3x.png`；返回原始文件数据（安装时原样写为 SBIcon.png）。
    private static func readIconData(appURL: URL, plist: [String: Any]) -> Data? {
        var iconNames: [String] = []
        if let icons = plist["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let last = files.last {
            iconNames.append(last)
        }
        iconNames.append("AppIcon60x60")

        for name in iconNames {
            // 图标条目通常不带扩展名和倍率后缀，逐个试 @3x / @2x / 无后缀。
            for candidate in ["\(name)@3x.png", "\(name)@2x.png", "\(name).png", name] {
                let iconURL = appURL.appendingPathComponent(candidate)
                if let data = try? Data(contentsOf: iconURL), !data.isEmpty {
                    return data
                }
            }
        }
        return nil
    }
}
