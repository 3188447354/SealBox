// SBKeychain.swift — 证书密码的系统钥匙串存取（设计 §4.3 的改进）。
//
// 0.1.0 把证书密码明文存在 App Group UserDefaults（SBCertificatePassword）；
// 本设计改存系统钥匙串：SecItem，kSecAttrAccessibleAfterFirstUnlock，
// service `com.mjorb.sealbox.certificate-password`，account 固定
// `certificate-password`。密码只在签名 / 校验时读进内存用，用完即放，
// 不落盘、不进 UserDefaults。
//
// 步骤 5 的 SBCertificate 导入 / 删除会复用这里的 save / read / delete；
// 本步先建 helper，并把 SBInstaller 的证书密码读路径改到这里。

import Foundation
import Security

/// 证书密码的钥匙串存取。
enum SBKeychain {

    static let service = "com.mjorb.sealbox.certificate-password"
    static let account = "certificate-password"

    /// 存密码：已有则更新，没有则新增。成功返回 true。
    static func save(password: String) -> Bool {
        guard let data = password.data(using: .utf8) else {
            return false
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return true
        }
        if status == errSecDuplicateItem {
            // 已存在：只更新密码数据，不动其它属性。
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let attributes: [String: Any] = [
                kSecValueData as String: data,
            ]
            return SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary) == errSecSuccess
        }
        return false
    }

    /// 读密码：没有存过返回 nil。
    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return password
    }

    /// 删密码：本来就没有也返回 true（不报错，调用方按“已清”处理）。
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
