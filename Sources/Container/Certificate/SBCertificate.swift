// SBCertificate.swift — 证书导入、校验、删除与启动链自测（证书文件存于 App Group）。
//
// 密码存系统钥匙串（SBKeychain，service `com.mjorb.sealbox.certificate-password`），
// 不再写 App Group UserDefaults 明文。删除时顺手清掉旧明文键 SBCertificatePassword
// 的残留（0.1.0 / 步骤 2 之前的做法留下的）。
// 导入日期（SBCertificateImportedDate）与有效期缓存（SBCertificateExpiryDate）是非敏感
// 信息，仍放 App Group UserDefaults，不变。

import Foundation
import Security
import UIKit
import UniformTypeIdentifiers

/// 证书管理：p12 导入 / 状态 / 删除 / 启动链自测。
///
/// 约定（按模块契约）：
/// - 证书文件在 App Group 容器内，文件名为 Certificate.p12；
/// - 密码存系统钥匙串（SBKeychain）；导入日期与有效期缓存存在 App Group UserDefaults
///   （键 SBCertificateImportedDate / SBCertificateExpiryDate），有效期缓存只用来拼
///   状态文案，不作他用；
/// - 证书相关失败一律抛 SBError；校验失败用 `.certificateInvalid(reason:)`，
///   自测失败用 `.selfTestFailed(stage:reason:)`。
public enum SBCertificate {

    // MARK: - 常量

    /// 旧明文密码键（0.1.0 做法）：不再写入，删除证书时清一次残留。
    private static let legacyPasswordKey = "SBCertificatePassword"
    private static let importedDateKey = "SBCertificateImportedDate"
    private static let expiryDateKey = "SBCertificateExpiryDate"

    /// 本进程内是否见过有效证书（供 checkStillExists 判断“证书丢了”用）。
    /// 跨进程靠“密码还在、文件没了”判断，不依赖本标记。
    private static var sawCertificate = false

    /// 状态文案缓存；为空时由 statusText 按存量信息现场算。
    private static var cachedStatusText: String?

    /// checkCert 最近一次结果的备忘（设置页进页时 refreshStatusText 与
    /// certificateInfo 各调一次 checkCert，60 秒内共用一次 OCSP 请求）。
    /// 只在主线程读写（见 checkCertRaw）。
    private static var lastCheckData: Data?
    private static var lastCheckPassword: String?
    private static var lastCheckResult: (status: Int, expirationDate: Date?, teamID: String?, error: String?)?
    private static var lastCheckAt: Date?

    // MARK: - 基础访问

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: SBConstants.appGroupSuiteName)
    }

    private static var certificateFileURL: URL? {
        SBConstants.appGroupContainerURL?
            .appendingPathComponent(SBConstants.certificateFileName)
    }

    /// 证书密码：只从系统钥匙串读，绝不读 UserDefaults 明文。
    private static var storedPassword: String? {
        SBKeychain.read()
    }

    // MARK: - 状态

    /// 是否有可用证书：p12 文件存在且钥匙串里密码非空。
    public static var hasCertificate: Bool {
        guard let url = certificateFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let password = storedPassword, !password.isEmpty else {
            return false
        }
        sawCertificate = true
        return true
    }

    /// 证书状态文案（同步读缓存；设置页出现时调 refreshStatusText() 异步刷新）。
    /// - 未导入：「未导入证书」
    /// - 有效：「证书有效，至 2026-12-01」
    /// - 7 天内过期：「证书将于 2026-12-01 过期，请及时重新导入」
    /// - 已过期：「证书已过期，请重新导入」
    /// - 校验失败：「证书校验失败，请重新导入证书」
    /// - 有效期未知：「证书已导入，有效期未知」
    public static var statusText: String {
        if let cached = cachedStatusText {
            return cached
        }
        return computedStatusText()
    }

    /// 异步刷新状态文案：用当前证书调 ZSigner 校验，拿到最新过期日后更新缓存并返回。
    /// 无证书返回「未导入证书」；校验失败返回「证书校验失败，请重新导入证书」。
    public static func refreshStatusText() async -> String {
        guard hasCertificate else {
            let text = "未导入证书"
            await MainActor.run { cachedStatusText = text }
            return text
        }
        guard let url = certificateFileURL,
              let data = try? Data(contentsOf: url),
              let password = storedPassword, !password.isEmpty else {
            let text = "证书校验失败，请重新导入证书"
            await MainActor.run { cachedStatusText = text }
            return text
        }
        do {
            let expiration = try await checkCertificate(data: data, password: password)
            let text = expiration.map { statusText(for: $0) } ?? "证书已导入，有效期未知"
            await MainActor.run {
                cachedStatusText = text
                if let expiration = expiration {
                    sharedDefaults?.set(expiration, forKey: expiryDateKey)
                }
            }
            return text
        } catch {
            let text = "证书校验失败，请重新导入证书"
            await MainActor.run { cachedStatusText = text }
            return text
        }
    }

    /// 证书是否还在：文件存在返回 true；文件没了、且本进程见过证书或密码还留着，
    /// 说明证书是被外部删掉的，返回 false，调用方应按 `.certificateDeleted` 引导用户重导；
    /// 从未导入过（文件、密码都没有）不算“丢了”，返回 true。
    public static func checkStillExists() -> Bool {
        if let url = certificateFileURL,
           FileManager.default.fileExists(atPath: url.path) {
            sawCertificate = true
            return true
        }
        if sawCertificate {
            return false
        }
        if let password = storedPassword, !password.isEmpty {
            return false
        }
        return true
    }

    // MARK: - 证书信息（全部取自证书本身，不编）

    /// 从证书本身解析出的真实信息。任一字段取不到即为 nil，调用方不显示该行，
    /// 不编默认值。无证书返回 nil。
    public struct SBCertificateInfo {
        /// 主体（SecCertificateCopySubjectSummary），如 "iPhone Developer: xxx (TEAMID)"。
        public let subject: String?
        /// 颁发者：证书 DER 里 issuer 的 CN（如
        /// "Apple Worldwide Developer Relations Certification Authority"）。
        /// iOS SDK 不暴露 SecCertificateCopyValues（macOS 才有），改从 DER 解析。
        public let issuer: String?
        /// 过期日：ZSigner.checkCert 回的 expirationDate，与 DER 的 NotAfter
        /// 交叉核对过；不一致时以 DER（Security 侧同一字段）的值为准。
        public let expirationDate: Date?
        /// Team ID：checkCert 回的 organizationalUnitName（OU 即 Team ID）；
        /// 取不到时退到主体括号里的部分（仍取自证书本身）。
        public let teamID: String?
        /// 导入日期（App Group UserDefaults 的 SBCertificateImportedDate）。
        public let importedDate: Date?
    }

    /// 读当前证书的真实信息。无证书、读不到文件、钥匙串无密码、p12 解不开
    /// （如密码错）时返回 nil。
    /// checkCert 失败（如离线导致 OCSP 请求失败）不抹掉整份信息：过期日与
    /// Team ID 退到 DER 解析结果，状态文案另由 refreshStatusText
    /// 按“证书校验失败”处理。
    public static func certificateInfo() async -> SBCertificateInfo? {
        guard let url = certificateFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let password = storedPassword, !password.isEmpty else {
            return nil
        }
        guard let cert = certificateFromP12(data: data, password: password) else {
            return nil
        }
        let subject: String? = SecCertificateCopySubjectSummary(cert) as String?
        // 颁发者 CN 与 NotAfter 从 DER 解析（见 certificateFieldsFromDER；
        // SecCertificateCopyValues 在 iOS SDK 里不存在，CI run 44204688056 实证）。
        let der = SecCertificateCopyData(cert) as Data?
        let fields: (issuerCN: String?, notAfter: Date?) = der.map { certificateFieldsFromDER($0) } ?? (issuerCN: nil, notAfter: nil)
        let issuer = fields.issuerCN
        let securityNotAfter = fields.notAfter

        let check = await checkCertRaw(data: data, password: password)
        var expiration = check.expirationDate
        if let securityDate = securityNotAfter {
            if let checkDate = expiration {
                if Swift.abs(checkDate.timeIntervalSince(securityDate)) > 60 {
                    NSLog("[SBCertificate] checkCert 过期日与 DER NotAfter 不一致，以 DER 为准：checkCert=%@ DER=%@",
                          checkDate as NSDate, securityDate as NSDate)
                    expiration = securityDate
                }
            } else {
                expiration = securityDate
            }
        }
        var teamID = check.teamID
        if teamID == nil, let summary = subject {
            teamID = teamIDFromSubjectSummary(summary)
        }
        let imported = sharedDefaults?.object(forKey: importedDateKey) as? Date
        return SBCertificateInfo(
            subject: subject,
            issuer: issuer,
            expirationDate: expiration,
            teamID: teamID,
            importedDate: imported)
    }

    // MARK: - 导入 / 删除

    /// 导入证书：文件选择器选 .p12 → 拷到 App Group Certificate.p12 →
    /// 弹密码框 → 调 ZSigner 校验 → 密码存钥匙串，存导入日期与有效期缓存。
    /// - Parameter presenter: 用来 present 选择器与密码框的视图控制器。
    /// - Throws: 用户取消抛 `SBError.cancelled`；密码为空或校验未通过抛
    ///   `SBError.certificateInvalid(reason:)`；文件落盘失败或钥匙串存密码失败抛
    ///   `SBError.generic(stage: "导入证书", message:)`。失败时刚拷入的文件会被清掉，
    ///   不留半截证书。
    public static func importP12(presenter: UIViewController) async throws {
        let pickedURL = try await pickP12(presenter: presenter)
        guard let destination = certificateFileURL else {
            throw SBError.generic(stage: "导入证书", message: "取不到应用共享目录：App Group 权限缺失，属签名问题，重装也解决不了")
        }
        guard let data = try? Data(contentsOf: pickedURL) else {
            throw SBError.generic(stage: "导入证书", message: "读不到所选证书文件，请重试")
        }

        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: pickedURL, to: destination)
        } catch {
            throw SBError.generic(stage: "导入证书", message: "证书文件保存失败，请重试")
        }

        do {
            let password = try await askPassword(presenter: presenter)
            let expiration = try await checkCertificate(data: data, password: password)
            guard SBKeychain.save(password: password) else {
                throw SBError.generic(stage: "导入证书", message: "证书密码保存失败，请重试")
            }
            await MainActor.run {
                sharedDefaults?.set(Date(), forKey: importedDateKey)
                if let expiration = expiration {
                    sharedDefaults?.set(expiration, forKey: expiryDateKey)
                } else {
                    sharedDefaults?.removeObject(forKey: expiryDateKey)
                }
                sawCertificate = true
                cachedStatusText = expiration.map { statusText(for: $0) } ?? "证书已导入，有效期未知"
            }
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    /// 删除证书：删 p12 文件，清钥匙串密码、导入日期与有效期缓存，并清掉
    /// 旧明文键 SBCertificatePassword 的残留。删后 hasCertificate 为 false。
    /// 文件本就不存在时也照常清键，不报错。
    public static func deleteCertificate() throws {
        let fileManager = FileManager.default
        if let url = certificateFileURL, fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw SBError.generic(stage: "删除证书", message: "删除证书文件失败，请重试")
            }
        }
        _ = SBKeychain.delete()
        sharedDefaults?.removeObject(forKey: legacyPasswordKey)
        sharedDefaults?.removeObject(forKey: importedDateKey)
        sharedDefaults?.removeObject(forKey: expiryDateKey)
        sawCertificate = false
        cachedStatusText = "未导入证书"
    }

    // MARK: - 启动链自测（F1）

    /// 启动链自测：先查应用共享目录（App Group 权限缺失时当场报，不走到证书门），
    /// 再过证书门，再调 SBGuestLoader 自测入口。
    /// 自测内部用信号量等 ZSign 回调，必须在后台线程跑，本方法已把调用派到全局队列，
    /// 调用方在主线程调本方法即可。设置页证书区直接调本入口。
    /// internal 即可：设置页与本文件在同一 App target 内；改成 public 会因返回
    /// 值里的 SBError 是 internal 类型而编译失败（CI run 44204688056 实证）。
    /// - Returns: 成功 `.success(())`；失败 `.failure(SBError)`，其中证书门失败为
    ///   `.missingCertificate` / `.certificateDeleted`，其余为
    ///   `.selfTestFailed(stage:reason:)`，stage 取自测返回的中文阶段名。
    static func runChainSelfTest() async -> Result<Void, SBError> {
        guard SBConstants.appGroupContainerURL != nil else {
            return .failure(.selfTestFailed(
                stage: "应用共享目录",
                reason: "App Group 权限缺失，取不到应用共享目录，属签名问题，重装也解决不了"))
        }
        if let gateError = certificateGateError() {
            return .failure(gateError)
        }
        guard let url = certificateFileURL,
              let data = try? Data(contentsOf: url),
              let password = storedPassword, !password.isEmpty else {
            return .failure(.missingCertificate)
        }
        do {
            let passed = try await runSelfTestOnBackground(data: data, password: password)
            if passed {
                return .success(())
            }
            return .failure(.selfTestFailed(stage: "自测", reason: "自测未通过，请重试"))
        } catch let nsError as NSError {
            return .failure(selfTestError(from: nsError))
        } catch {
            return .failure(.selfTestFailed(stage: "自测", reason: error.localizedDescription))
        }
    }

    // MARK: - 私有：证书门与自测错误映射

    /// 证书门：文件与密码齐全返回 nil；有密码无文件返回 `.certificateDeleted`；
    /// 其余缺失返回 `.missingCertificate`。
    private static func certificateGateError() -> SBError? {
        let fileExists = certificateFileURL
            .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let hasPassword = storedPassword.map { !$0.isEmpty } ?? false
        if fileExists && hasPassword {
            return nil
        }
        if hasPassword && !fileExists {
            return .certificateDeleted
        }
        return .missingCertificate
    }

    /// 自测入口放后台队列跑（内部阻塞等回调，绝不在主线程调）。
    private static func runSelfTestOnBackground(data: Data, password: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // ObjC 的 BOOL + NSError** 方法导入成 Swift 的 () throws：
                    // 成功不抛错即通过，失败抛错；BOOL 返回值不进 Swift。
                    try SBGuestLoader.runSelfTest(withCertificate: data, password: password)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// NSError → SBError：1001 缺证书、1002 证书被删（与 SBGuestLoader 错误码一致）；
    /// 其余取 userInfo 里中文阶段名（键 SBGuestLoaderErrorStage），包成 selfTestFailed。
    private static func selfTestError(from nsError: NSError) -> SBError {
        switch nsError.code {
        case 1001:
            return .missingCertificate
        case 1002:
            return .certificateDeleted
        default:
            let stage = nsError.userInfo["SBGuestLoaderErrorStage"] as? String ?? "自测"
            return .selfTestFailed(stage: stage, reason: nsError.localizedDescription)
        }
    }

    // MARK: - 私有：状态文案

    private static func computedStatusText() -> String {
        guard hasCertificate else {
            return "未导入证书"
        }
        guard let expiration = sharedDefaults?.object(forKey: expiryDateKey) as? Date else {
            return "证书已导入，有效期未知"
        }
        return statusText(for: expiration)
    }

    private static func statusText(for expiration: Date) -> String {
        let dateString = formattedDate(expiration)
        if expiration < Date() {
            return "证书已过期，请重新导入"
        }
        if expiration.timeIntervalSinceNow < 7 * 24 * 60 * 60 {
            return "证书将于 \(dateString) 过期，请及时重新导入"
        }
        return "证书有效，至 \(dateString)"
    }

    /// 每次新建 formatter（DateFormatter 非线程安全，本模块会在回调线程拼文案）。
    private static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - 私有：ZSigner 校验

    /// 调 ZSigner.checkCert 校验 p12，返回 (status, 过期日, Team ID, 错误文案)，
    /// 不抛错：调用方按 status 决定是有效还是失败。
    /// 60 秒内同一份 p12 + 密码重复调直接复用上次结果（备忘只在主线程读写）。
    private static func checkCertRaw(data: Data, password: String) async -> (status: Int, expirationDate: Date?, teamID: String?, error: String?) {
        let cached: (status: Int, expirationDate: Date?, teamID: String?, error: String?)? = await MainActor.run {
            if let at = lastCheckAt,
               let cachedData = lastCheckData,
               let cachedPassword = lastCheckPassword,
               let result = lastCheckResult,
               cachedData == data, cachedPassword == password,
               Date().timeIntervalSince(at) < 60 {
                return result
            }
            return nil
        }
        if let cached = cached {
            return cached
        }
        let result: (status: Int, expirationDate: Date?, teamID: String?, error: String?) = await withCheckedContinuation { (continuation: CheckedContinuation<(status: Int, expirationDate: Date?, teamID: String?, error: String?), Never>) in
            ZSigner.checkCert(data, pass: password) { status, expirationDate, organizationalUnitName, errorString in
                continuation.resume(returning: (status: Int(status), expirationDate: expirationDate, teamID: organizationalUnitName, error: errorString))
            }
        }
        await MainActor.run {
            lastCheckData = data
            lastCheckPassword = password
            lastCheckResult = result
            lastCheckAt = Date()
        }
        return result
    }

    /// 调 ZSigner.checkCert 校验 p12：status 为 0 才算有效，返回过期日；
    /// 否则按 ZSigner 回的错误文案抛 `.certificateInvalid(reason:)`。
    ///
    /// status 语义（已按 ZSign/zsign.mm 源码确认，不是假设）：
    /// - status 是 OCSP 响应里的证书状态（OCSP_resp_find_status）：
    ///   0 = GOOD（未吊销）、1 = REVOKED（已吊销）、2 = UNKNOWN；
    /// - 口令错（InitSimple 失败）、颁发者不是 Apple 开发 CA（issuer hash 不匹配）、
    ///   无 AIA / 无 OCSP 地址、OCSP 联网失败、OCSP 响应解码失败，全部以 status 2
    ///   + 错误文案回，见 zsign.mm 的 checkCert；
    /// - checkCert 本身不判过期：expirationDate 只是 X509 notAfter 解析出的日期，
    ///   过期与否由本模块按该日期与当前时间比对（statusText(for:)）；
    /// - OCSP 要联网：离线时校验失败，文案为网络错误原文；
    /// - ZSigner.checkCert 的 int 返回值（-1…-6 / 1）只表示异步任务是否发出，
    ///   Swift 侧只看 completionHandler 的 status，不读它。
    /// 仍需真机验证（源码确认不了）：拿已知好证书与已知坏口令的证书各跑一次，
    /// 核对 status / expirationDate / organizationalUnitName / errorString
    /// 四个返回值与源码结论一致；另需确认非签名用途的 Apple 证书是否也会
    /// 回 status 0（checkCert 只认 Apple 颁发者 + OCSP GOOD，不验代码签名用途）。
    private static func checkCertificate(data: Data, password: String) async throws -> Date? {
        let result = await checkCertRaw(data: data, password: password)
        if result.status == 0 {
            return result.expirationDate
        }
        let reason = result.error ?? "证书校验未通过（状态码 \(result.status)）"
        throw SBError.certificateInvalid(reason: reason)
    }

    // MARK: - 私有：Security 框架解析

    /// SecPKCS12Import 解 p12 取首个身份的证书。解不开（密码错、文件损坏）
    /// 返回 nil。CF 类型不用 `as?` 条件转换（编译器直接报错，见 70945ca3
    /// 教训），先取 Any 再 `as!` 强制转换。
    private static func certificateFromP12(data: Data, password: String) -> SecCertificate? {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identityValue = first[kSecImportItemIdentity as String] else {
            return nil
        }
        let identity = identityValue as! SecIdentity
        var cert: SecCertificate?
        let copyStatus = SecIdentityCopyCertificate(identity, &cert)
        guard copyStatus == errSecSuccess else {
            return nil
        }
        return cert
    }

    // MARK: - 私有：证书 DER 解析（iOS 侧）

    /// 一个 DER TLV 的位置信息。
    private typealias DERTLV = (tag: UInt8, contentOffset: Int, contentLength: Int, nextOffset: Int)

    /// iOS SDK 不暴露 SecCertificateCopyValues（macOS 才有，CI run 44204688056
    /// 实证：SecCertificateCopyValues / kSecOIDX509V1* / kSecPropertyKey* 全都
    /// "cannot find in scope"），颁发者与 NotAfter 改从 SecCertificateCopyData
    /// 的 DER 直接解析。DER 是严格定长编码，解析失败只返回 nil（该行不显示），
    /// 绝不崩、不编值。
    ///
    /// 结构（RFC 5280）：Certificate SEQ { tbsCertificate SEQ, … }；
    /// tbsCertificate SEQ { [0] version（可选）, INTEGER serial, SEQ signature,
    /// SEQ issuer, SEQ validity, … }；issuer 是 Name（SEQ OF SET OF SEQ { OID,
    /// value }）；validity 是 SEQ { notBefore Time, notAfter Time }。
    private static func certificateFieldsFromDER(_ der: Data) -> (issuerCN: String?, notAfter: Date?) {
        guard let certTLV = readDERTLV(der, at: 0), certTLV.tag == 0x30 else {
            return (issuerCN: nil, notAfter: nil)
        }
        let certChildren = derChildren(of: der, contentOffset: certTLV.contentOffset, contentLength: certTLV.contentLength)
        guard let tbs = certChildren.first, tbs.tag == 0x30 else {
            return (issuerCN: nil, notAfter: nil)
        }
        let tbsChildren = derChildren(of: der, contentOffset: tbs.contentOffset, contentLength: tbs.contentLength)
        var index = 0
        if index < tbsChildren.count, tbsChildren[index].tag == 0xA0 {
            index += 1 // version [0]，可选
        }
        index += 1 // serial INTEGER
        index += 1 // signature SEQ
        guard index < tbsChildren.count else {
            return (issuerCN: nil, notAfter: nil)
        }
        var issuerCN: String? = nil
        let issuerTLV = tbsChildren[index]
        index += 1
        if issuerTLV.tag == 0x30 {
            issuerCN = commonName(from: der, nameTLV: issuerTLV)
        }
        var notAfter: Date? = nil
        if index < tbsChildren.count, tbsChildren[index].tag == 0x30 {
            let validity = tbsChildren[index]
            let validityChildren = derChildren(of: der, contentOffset: validity.contentOffset, contentLength: validity.contentLength)
            if validityChildren.count >= 2 {
                notAfter = timeDate(from: der, tlv: validityChildren[1])
            }
        }
        return (issuerCN: issuerCN, notAfter: notAfter)
    }

    /// 读一个 DER TLV：返回 tag 与内容/下一项位置；越界返回 nil。
    /// 只处理单字节 tag（本结构里出现的 tag 都是单字节）与定长长度
    /// （短式或最长 4 字节长式）。
    private static func readDERTLV(_ data: Data, at offset: Int) -> DERTLV? {
        guard offset + 2 <= data.count else {
            return nil
        }
        let tag = data[offset]
        var index = offset + 1
        let firstLengthByte = data[index]
        index += 1
        var length = 0
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            let lengthByteCount = Int(firstLengthByte & 0x7F)
            guard lengthByteCount > 0, lengthByteCount <= 4,
                  index + lengthByteCount <= data.count else {
                return nil
            }
            for i in 0..<lengthByteCount {
                length = (length << 8) | Int(data[index + i])
            }
            index += lengthByteCount
        }
        guard index + length <= data.count else {
            return nil
        }
        return (tag: tag, contentOffset: index, contentLength: length, nextOffset: index + length)
    }

    /// 取一个 SEQUENCE / SET 的直接子项 TLV 列表；中途越界即停（不抛错）。
    private static func derChildren(of data: Data, contentOffset: Int, contentLength: Int) -> [DERTLV] {
        var children: [DERTLV] = []
        var offset = contentOffset
        let end = contentOffset + contentLength
        while offset < end {
            guard let tlv = readDERTLV(data, at: offset) else {
                break
            }
            children.append(tlv)
            offset = tlv.nextOffset
        }
        return children
    }

    /// 从 issuer Name 里找 OID 2.5.4.3（CN）的值。
    private static func commonName(from der: Data, nameTLV: DERTLV) -> String? {
        let cnOID: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]
        let rdns = derChildren(of: der, contentOffset: nameTLV.contentOffset, contentLength: nameTLV.contentLength)
        for rdn in rdns where rdn.tag == 0x31 {
            let pairs = derChildren(of: der, contentOffset: rdn.contentOffset, contentLength: rdn.contentLength)
            for pair in pairs where pair.tag == 0x30 {
                let fields = derChildren(of: der, contentOffset: pair.contentOffset, contentLength: pair.contentLength)
                guard fields.count >= 2, fields[0].tag == 0x06 else {
                    continue
                }
                let oidBytes = der[fields[0].contentOffset..<(fields[0].contentOffset + fields[0].contentLength)]
                if Array(oidBytes) == cnOID {
                    return stringValue(from: der, tlv: fields[1])
                }
            }
        }
        return nil
    }

    /// DER 字符串值按 tag 解码：UTF8 / Printable / Teletex / IA5 按 UTF-8，
    /// BMPString 按 UTF-16BE；其它 tag 返回 nil。
    private static func stringValue(from der: Data, tlv: DERTLV) -> String? {
        let bytes = der[tlv.contentOffset..<(tlv.contentOffset + tlv.contentLength)]
        switch tlv.tag {
        case 0x0C, 0x13, 0x14, 0x16:
            return String(bytes: bytes, encoding: .utf8)
        case 0x1E:
            return String(bytes: bytes, encoding: .utf16BigEndian)
        default:
            return nil
        }
    }

    /// DER Time 值转 Date：UTCTime "YYMMDDHHMMSSZ"（与 zsign.mm 的 "20" 前缀
    /// 口径一致，即 20xx 年）、GeneralizedTime "YYYYMMDDHHMMSSZ"；
    /// 秒缺失或其它格式解析失败返回 nil（调用方退到 checkCert 的过期日）。
    private static func timeDate(from der: Data, tlv: DERTLV) -> Date? {
        guard let text = stringValue(from: der, tlv: tlv) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if tlv.tag == 0x17 {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return formatter.date(from: text)
        }
        if tlv.tag == 0x18 {
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            return formatter.date(from: text)
        }
        return nil
    }

    /// 主体括号里的部分即 Team ID（如 "iPhone Developer: xxx (TEAMID)"），
    /// 仅作 checkCert 的 OU 取不到时的退路，仍取自证书本身。
    private static func teamIDFromSubjectSummary(_ summary: String) -> String? {
        guard let open = summary.lastIndex(of: "("),
              let close = summary.lastIndex(of: ")"),
              open < close else {
            return nil
        }
        let teamID = String(summary[summary.index(after: open)..<close])
        return teamID.isEmpty ? nil : teamID
    }

    // MARK: - 私有：文件选择器与密码框（主线程）

    /// 弹出系统文件选择器，只收 .p12。用户取消抛 `.cancelled`。
    @MainActor
    private static func pickP12(presenter: UIViewController) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let p12Type = UTType(tag: "p12", tagClass: .filenameExtension, conformingTo: .data)
            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: p12Type.map { [$0] } ?? [.data],
                asCopy: true
            )
            picker.allowsMultipleSelection = false
            let delegate = SBDocumentPickerDelegate()
            delegate.onPick = { url in
                if url.pathExtension.lowercased() == "p12" {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: SBError.certificateInvalid(reason: "所选文件不是 .p12 证书"))
                }
            }
            delegate.onCancel = {
                continuation.resume(throwing: SBError.cancelled)
            }
            picker.delegate = delegate
            delegate.keepAlive()
            presenter.present(picker, animated: true, completion: nil)
        }
    }

    /// 弹密码输入框（UIAlertController + 安全文本框）。取消抛 `.cancelled`，
    /// 密码为空抛 `.certificateInvalid(reason: "密码不能为空")`。
    @MainActor
    private static func askPassword(presenter: UIViewController) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let alert = UIAlertController(
                title: "输入证书密码",
                message: "请输入该 .p12 文件的导出密码",
                preferredStyle: .alert
            )
            alert.addTextField { textField in
                textField.isSecureTextEntry = true
                textField.placeholder = "证书密码"
                textField.returnKeyType = .done
            }
            let cancel = UIAlertAction(title: "取消", style: .cancel) { _ in
                continuation.resume(throwing: SBError.cancelled)
            }
            let confirm = UIAlertAction(title: "确定", style: .default) { _ in
                let password = alert.textFields?.first?.text ?? ""
                if password.isEmpty {
                    continuation.resume(throwing: SBError.certificateInvalid(reason: "密码不能为空"))
                } else {
                    continuation.resume(returning: password)
                }
            }
            alert.addAction(cancel)
            alert.addAction(confirm)
            presenter.present(alert, animated: true, completion: nil)
        }
    }
}

/// 文件选择器的 delegate 适配器：把 delegate 回调转成一次性闭包。
/// 用 `keepAlive()` 自持有，回调完成后立即释放，避免循环引用。
private final class SBDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {

    var onPick: ((URL) -> Void)?
    var onCancel: (() -> Void)?

    private var selfRetain: SBDocumentPickerDelegate?

    func keepAlive() {
        selfRetain = self
    }

    private func releaseAlive() {
        selfRetain = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        releaseAlive()
        if let url = urls.first {
            onPick?(url)
        } else {
            onCancel?()
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        releaseAlive()
        onCancel?()
    }
}
