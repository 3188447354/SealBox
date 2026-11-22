import Foundation
import Security

/// 真删客 App：bundle 目录 + 数据容器 + 钥匙串记录（尽力而为）+ Store 记录。
/// 文件删除失败时抛错（桌面不动、只弹错）；钥匙串删除按组清，失败不拦。
enum SBAppDeletion {

    static func delete(app: SBInstalledApp) throws {
        let fileManager = FileManager.default
        var firstError: Error?

        if fileManager.fileExists(atPath: app.bundleURL.path) {
            do {
                try fileManager.removeItem(at: app.bundleURL)
            } catch {
                firstError = firstError ?? SBError.generic(
                    stage: "删除应用", message: "删除应用本体失败：\(error.localizedDescription)")
            }
        }

        if fileManager.fileExists(atPath: app.dataContainerURL.path) {
            do {
                try fileManager.removeItem(at: app.dataContainerURL)
            } catch {
                firstError = firstError ?? SBError.generic(
                    stage: "删除应用", message: "删除应用数据失败：\(error.localizedDescription)")
            }
        }

        deleteKeychainItems(group: SBConstants.keychainGroupName(for: app.keychainGroup))
        // 0.2.44：删客同时清偏好残留——旧 suite（纯 bundleID，0.2.43 及
        // 以前）与新 suite（bundleID.容器 UUID，0.2.44 起）都清；容器侧
        // 偏好随容器目录一起删。removePersistentDomain 是尽力而为，
        // 失败不拦（删客本体失败才抛错）。
        deleteGuestPreferences(bundleID: app.bundleID, containerUUID: app.containerUUID)
        SBStore.shared.removeAppRecord(recordID: app.recordID)

        if let firstError = firstError {
            throw firstError
        }
    }

    /// 按客 bundleID＋容器 UUID 清偏好套件：removePersistentDomain（宿主
    /// Library/Preferences 下的套件文件）＋尽力而为删同名 plist 文件。
    /// 客偏好 plist 的实际落盘位置（宿主 vs 容器）由 CFPreferences 解析，
    /// 代码钉不死——此处两处都清，残留以真机核查为准（见 build log）。
    private static func deleteGuestPreferences(bundleID: String, containerUUID: String) {
        let suites = [bundleID, "\(bundleID).\(containerUUID)"]
        for suite in suites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            let plist = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: plist)
        }
    }

    /// 按 access group 清该客 App 的钥匙串记录：常见五类各删一次，忽略结果。
    private static func deleteKeychainItems(group: String) {
        let classes: [CFString] = [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassIdentity,
            kSecClassCertificate,
            kSecClassKey,
        ]
        for itemClass in classes {
            let query: [String: Any] = [
                kSecClass as String: itemClass,
                kSecAttrAccessGroup as String: group,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
