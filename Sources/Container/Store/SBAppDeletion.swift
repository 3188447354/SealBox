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
        SBStore.shared.removeAppRecord(recordID: app.recordID)

        if let firstError = firstError {
            throw firstError
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
