// SBCertificate.swift — 证书导入、校验、删除与启动链自测（证书文件存于 App Group）。

import Foundation
import UIKit
import UniformTypeIdentifiers

/// 证书管理：p12 导入 / 状态 / 删除 / 启动链自测。
///
/// 约定（按模块契约）：
/// - 证书文件在 App Group 容器内，文件名为 Certificate.p12；
/// - 密码与导入日期存在 App Group UserDefaults（键 SBCertificatePassword /
///   SBCertificateImportedDate）；有效期缓存键 SBCertificateExpiryDate 是本模块自有键，
///   只用来拼状态文案，不作他用；
/// - 证书相关失败一律抛 SBError；校验失败用 `.certificateInvalid(reason:)`，
///   自测失败用 `.selfTestFailed(stage:reason:)`。
public enum SBCertificate {

    // MARK: - 常量

    private static let passwordKey = "SBCertificatePassword"
    private static let importedDateKey = "SBCertificateImportedDate"
    private static let expiryDateKey = "SBCertificateExpiryDate"

    /// 本进程内是否见过有效证书（供 checkStillExists 判断“证书丢了”用）。
    /// 跨进程靠“密码还在、文件没了”判断，不依赖本标记。
    private static var sawCertificate = false

    /// 状态文案缓存；为空时由 statusText 按存量信息现场算。
    private static var cachedStatusText: String?

    // MARK: - 基础访问

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: SBConstants.appGroupSuiteName)
    }

    private static var certificateFileURL: URL? {
        SBConstants.appGroupContainerURL?
            .appendingPathComponent(SBConstants.certificateFileName)
    }

    private static var storedPassword: String? {
        sharedDefaults?.string(forKey: passwordKey)
    }

    // MARK: - 状态

    /// 是否有可用证书：p12 文件存在且密码非空。
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

    // MARK: - 导入 / 删除

    /// 导入证书：文件选择器选 .p12 → 拷到 App Group Certificate.p12 →
    /// 弹密码框 → 调 ZSigner 校验 → 存密码与导入日期。
    /// - Parameter presenter: 用来 present 选择器与密码框的视图控制器。
    /// - Throws: 用户取消抛 `SBError.cancelled`；密码为空或校验未通过抛
    ///   `SBError.certificateInvalid(reason:)`；文件落盘失败抛
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
            await MainActor.run {
                sharedDefaults?.set(password, forKey: passwordKey)
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

    /// 删除证书：删 p12 文件，清密码、导入日期与有效期缓存。删后 hasCertificate 为 false。
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
        sharedDefaults?.removeObject(forKey: passwordKey)
        sharedDefaults?.removeObject(forKey: importedDateKey)
        sharedDefaults?.removeObject(forKey: expiryDateKey)
        sawCertificate = false
        cachedStatusText = "未导入证书"
    }

    // MARK: - 启动链自测（F1）

    /// 启动链自测：先查应用共享目录（App Group 权限缺失时当场报，不走到证书门），
    /// 再过证书门，再调 SBGuestLoader 自测入口。
    /// 自测内部用信号量等 ZSign 回调，必须在后台线程跑，本方法已把调用派到全局队列，
    /// 调用方在主线程调本方法即可。
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

    /// 调 ZSigner.checkCert 校验 p12：status 为 0 才算有效，返回过期日；
    /// 否则按 ZSigner 回的错误文案抛 `.certificateInvalid(reason:)`。
    private static func checkCertificate(data: Data, password: String) async throws -> Date? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Date?, Error>) in
            ZSigner.checkCert(data, pass: password) { status, expirationDate, _, errorString in
                if status == 0 {
                    continuation.resume(returning: expirationDate)
                } else {
                    let reason = errorString ?? "证书校验未通过（状态码 \(status)）"
                    continuation.resume(throwing: SBError.certificateInvalid(reason: reason))
                }
            }
        }
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
