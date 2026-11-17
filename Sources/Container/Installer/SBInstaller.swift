// SBInstaller.swift — 安装管线：拷包落位（80%）→ 打补丁 + 重签（20%）→ 登记入库。

import CryptoKit
import Foundation
import Security

/// 安装管线。
///
/// 调用约定（按模块契约）：
/// - `progress` 由调用方创建，总量须为 100；本方法挂两个子进度：拷包落位 80、打补丁 + 签名 20。
/// - 同名处理由调用方先问用户，决定后用 `existing` 传入：
///   `existing != nil` 表示**替换**（删旧包、复用旧数据容器与钥匙串组）；
///   `existing == nil` 但磁盘上已有同名包，表示**平行安装**，新包目录名加
///   `_<CFAbsoluteTime>` 后缀（Bundle ID 不变）。
/// - 加密 IPA 抛 `SBError.encryptedIPA`；签名失败不回滚，照样装完并记 `signed = false`
///  （详情页标「未签名 / JIT 启动」）；其它失败会清掉本次落位的文件与新建容器，
///   替换失败时还会把旧包恢复原位。
/// - 正在安装时不排队：由调用方在调本方法前拦截并 toast「正在安装，请稍候」。
public enum SBInstaller {

    /// 执行一次安装。
    /// - Parameters:
    ///   - parsed: `SBIPAParser.parse` 的解析结果（临时目录内的 .app）。
    ///   - progress: 调用方创建的总进度（总量 100）。
    ///   - existing: 已装的同 Bundle ID 应用；替换时传它，平行安装或全新安装时传 nil。
    /// - Returns: 登记入库后的已装应用记录。
    /// - Throws: `SBError.encryptedIPA` / `SBError.patchFailed` / `SBError.unzipFailed`
    ///  （拷包阶段的 I/O 失败，见 MODULE_NOTES）等；任务取消时抛 `CancellationError`。
    static func install(
        parsed: SBParsedIPA,
        progress: Progress,
        existing: SBInstalledApp?
    ) async throws -> SBInstalledApp {
        let fileManager = FileManager.default
        let appsDir = SBConstants.guestAppsDir
        let dataDir = SBConstants.guestDataDir

        // 解析时的临时根目录（…/SBIPAParser-<UUID>/）：无论成败、取消与否，
        // 函数退出时都清理，绝不留给调用方。
        let stagingRoot = stagingRoot(for: parsed.appURL)
        defer {
            try? fileManager.removeItem(at: stagingRoot)
        }

        try Task.checkCancellation()

        do {
            try fileManager.createDirectory(at: appsDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        } catch {
            throw SBError.unzipFailed(underlying: "创建应用目录失败")
        }

        // ---- 落位目录：替换用原目录名，平行安装加时间戳后缀 ----
        let isReplace = existing != nil
        var destinationDir = appsDir.appendingPathComponent(parsed.bundleID + ".app", isDirectory: true)
        if fileManager.fileExists(atPath: destinationDir.path), !isReplace {
            let suffix = Int(CFAbsoluteTimeGetCurrent())
            destinationDir = appsDir.appendingPathComponent(
                "\(parsed.bundleID)_\(suffix).app", isDirectory: true
            )
        }

        // ---- 进度：拷包 80 / 打补丁 + 签名 20 ----
        let copyProgress = Progress(totalUnitCount: 80)
        progress.addChild(copyProgress, withPendingUnitCount: 80)
        let patchProgress = Progress(totalUnitCount: 20)
        progress.addChild(patchProgress, withPendingUnitCount: 20)

        // 本次落位是否已开始往目标目录写东西：只在它为 true 时，失败清理才删目标目录。
        // （替换备份移动失败时目标目录里还是用户旧包，绝不能删。）
        var backupDir: URL?
        var didStartCopy = false
        var createdContainerUUID: String?

        do {
            // 替换时先把旧包挪到临时备份处：新包失败可原样恢复，不丢用户旧包。
            if isReplace, fileManager.fileExists(atPath: destinationDir.path) {
                backupDir = fileManager.temporaryDirectory
                    .appendingPathComponent("SBReplaceBackup-\(UUID().uuidString).app", isDirectory: true)
                do {
                    try fileManager.moveItem(at: destinationDir, to: backupDir!)
                } catch {
                    backupDir = nil
                    throw SBError.unzipFailed(underlying: "备份旧应用失败")
                }
            }

            // ---- 阶段一：拷包落位（80%，按实际字节数推进，是真实进度） ----
            didStartCopy = true
            let totalBytes = directoryByteSize(parsed.appURL)
            copyProgress.totalUnitCount = max(totalBytes, 1)
            try copyDirectory(from: parsed.appURL, to: destinationDir, progress: copyProgress)
            copyProgress.completedUnitCount = copyProgress.totalUnitCount
            try Task.checkCancellation()

            // ---- 阶段二：打补丁（20% 的前一半） ----
            let executablePath = destinationDir
                .appendingPathComponent(parsed.executableName).path
            guard fileManager.fileExists(atPath: executablePath) else {
                throw SBError.patchFailed(reason: "找不到可执行文件 \(parsed.executableName)")
            }
            let hooksDylibPath = "@loader_path/../../Tweaks/\(SBConstants.guestHooksDylibName)"
            let patchResult = SBMachOPatchExecutable(executablePath, hooksDylibPath)
            guard patchResult == SB_MACHO_PATCH_OK else {
                throw patchError(for: patchResult)
            }
            patchProgress.completedUnitCount = 10
            try Task.checkCancellation()

            // ---- 阶段二：重签（20% 的后一半）。失败不回滚，记未签名继续装。----
            // 签名成功时记当前证书的 SHA-256 指纹（证书更换后靠它判断是否需要
            // 重签，设计 §4.7）；证书不可读时记 nil，不阻塞安装；未签名记 nil。
            var signed = false
            var signingCertFingerprint: String? = nil
            if let certData = certificateData(),
               let password = certificatePassword(),
               !password.isEmpty {
                do {
                    try await signApp(
                        appPath: destinationDir.path,
                        bundleID: parsed.bundleID,
                        certData: certData,
                        password: password,
                        progress: patchProgress
                    )
                    signed = true
                    signingCertFingerprint = certificateFingerprint(certData: certData, password: password)
                } catch {
                    // 验收 C5：签名失败也照样装，详情页标「未签名 / JIT 启动」。
                    signed = false
                }
            }
            patchProgress.completedUnitCount = patchProgress.totalUnitCount

            // ---- 图标：解析出的图标原样写为 SBIcon.png，没有则不写（用默认图标） ----
            if let iconData = parsed.iconData {
                try? iconData.write(
                    to: destinationDir.appendingPathComponent("SBIcon.png"),
                    options: [.atomic]
                )
            }

            // ---- 数据容器与钥匙串组 ----
            // 替换复用旧容器与旧钥匙串组（保留用户数据）；平行 / 全新安装新建。
            let containerUUID = existing?.containerUUID ?? UUID().uuidString
            createdContainerUUID = existing == nil ? containerUUID : nil
            let containerDir = dataDir.appendingPathComponent(containerUUID, isDirectory: true)
            try fileManager.createDirectory(
                at: containerDir.appendingPathComponent("Documents", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: containerDir.appendingPathComponent("Library/Caches", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: containerDir.appendingPathComponent("tmp", isDirectory: true),
                withIntermediateDirectories: true
            )

            let keychainGroup = existing?.keychainGroup ?? allocateKeychainGroup()

            // ---- 登记入库 ----
            // 替换复用旧记录的 recordID（upsert 按 recordID 匹配，原位更新）；
            // 平行 / 全新安装用新 UUID（两条同名记录共存）。
            let record = SBInstalledApp(
                recordID: existing?.recordID ?? UUID(),
                bundleID: parsed.bundleID,
                displayName: parsed.displayName,
                version: parsed.version,
                shortVersion: parsed.version,
                executableName: parsed.executableName,
                containerUUID: containerUUID,
                keychainGroup: keychainGroup,
                installedDate: Date(),
                patchRevision: SBConstants.patchRevision,
                signed: signed,
                needsJIT: false,
                lastLaunchResult: nil,
                signingCertFingerprint: signingCertFingerprint,
                diskDirectoryName: destinationDir.lastPathComponent
            )
            SBStore.shared.upsertApp(record)

            // ---- 收尾：清替换备份（临时目录由函数入口的 defer 清理） ----
            if let backupDir = backupDir {
                try? fileManager.removeItem(at: backupDir)
            }
            progress.completedUnitCount = progress.totalUnitCount
            return record
        } catch {
            // 安装失败：只清本次新建的东西，不留半截图标；
            // 替换失败时把旧包从备份处恢复原位。
            if didStartCopy {
                try? fileManager.removeItem(at: destinationDir)
            }
            if let createdContainerUUID = createdContainerUUID {
                try? fileManager.removeItem(
                    at: dataDir.appendingPathComponent(createdContainerUUID, isDirectory: true)
                )
            }
            if let backupDir = backupDir, fileManager.fileExists(atPath: backupDir.path) {
                try? fileManager.moveItem(at: backupDir, to: destinationDir)
            }
            throw error
        }
    }

    /// 从解析出的 .app 路径反推解析时的临时根目录：往上找到名字以
    /// "SBIPAParser-" 开头的目录。不用固定删两级，因为 .app 可能不在
    /// Payload/ 下（直接位于临时根目录时删两级会误删临时目录本身）。
    private static func stagingRoot(for appURL: URL) -> URL {
        var dir = appURL.deletingLastPathComponent()
        while !dir.lastPathComponent.hasPrefix("SBIPAParser-") {
            let parent = dir.deletingLastPathComponent()
            if parent == dir {
                break
            }
            dir = parent
        }
        return dir
    }

    // MARK: - 补丁错误码 → SBError

    private static func patchError(for code: Int32) -> SBError {
        switch code {
        case SB_MACHO_PATCH_ERR_ENCRYPTED:
            return .encryptedIPA
        case SB_MACHO_PATCH_ERR_UNSUPPORTED_32BIT:
            return .patchFailed(reason: "该应用为 32 位应用，无法在不开启 JIT 的情况下运行")
        case SB_MACHO_PATCH_ERR_NO_SPACE:
            return .patchFailed(reason: "可执行文件内没有足够空间注入启动组件")
        case SB_MACHO_PATCH_ERR_SEG_COUNT_MISMATCH:
            return .patchFailed(reason: "链式修正段数与实际段数不一致")
        case SB_MACHO_PATCH_ERR_UNSUPPORTED_ARCH:
            return .patchFailed(reason: "该应用不是 arm64 架构")
        default:
            return .patchFailed(reason: "打补丁失败（错误码 \(code)）")
        }
    }

    // MARK: - 钥匙串组分配

    /// 在 0..<keychainGroupCount 里挑一个未被占用的组；128 组全满时随机复用一组。
    private static func allocateKeychainGroup() -> Int {
        let used = Set(SBStore.shared.loadInstalledApps().map { $0.keychainGroup })
        let count = SBConstants.keychainGroupCount
        guard count > 0 else { return 0 }
        if let free = (0..<count).first(where: { !used.contains($0) }) {
            return free
        }
        return Int.random(in: 0..<count)
    }

    // MARK: - 证书读取（安装时重签用）

    /// App Group 共享容器内的 Certificate.p12；没有则返回 nil，安装走未签名分支。
    private static func certificateData() -> Data? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SBConstants.appGroupSuiteName
        ) else {
            return nil
        }
        return try? Data(contentsOf: container.appendingPathComponent("Certificate.p12"))
    }

    /// 证书密码改存系统钥匙串（SBKeychain），不再读 App Group UserDefaults 明文。
    /// 步骤 5 的 SBCertificate 导入会把密码写进同一钥匙串。
    private static func certificatePassword() -> String? {
        SBKeychain.read()
    }

    /// 取 p12 里首个身份的证书，做 SecCertificateCopyData 后取 SHA-256 hex。
    /// 证书不可读（口令错、p12 损坏等）时返回 nil，不阻塞安装。
    private static func certificateFingerprint(certData: Data, password: String) -> String? {
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        guard SecPKCS12Import(certData as CFData, options as CFDictionary, &items) == errSecSuccess,
              let array = items as? [[String: Any]],
              let identityDict = array.first,
              let rawIdentity = identityDict[kSecImportItemIdentity as String] else {
            return nil
        }
        // 注意：不能写 `as? SecIdentity`——对 CoreFoundation 类型做条件转换，
        // 编译器判“恒成功”而直接报错；这里先取 Any 再强制转换（该键的值按
        // SecPKCS12Import 约定就是 SecIdentity，键缺失时上面已返回 nil）。
        let identity = rawIdentity as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate = certificate else {
            return nil
        }
        let derData = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: derData)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 调 ObjC++ 包装 `SBSigner` 对整个 .app 重签；失败抛 `SBError.signFailed`。
    private static func signApp(
        appPath: String,
        bundleID: String,
        certData: Data,
        password: String,
        progress: Progress
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            SBSigner.signApp(
                atPath: appPath,
                bundleID: bundleID,
                certData: certData,
                password: password,
                progress: progress
            ) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: SBError.signFailed(
                            reason: error?.localizedDescription ?? "签名失败"
                        )
                    )
                }
            }
        }
    }

    // MARK: - 目录拷贝（带真实字节进度）

    /// 统计目录下全部文件的字节总数（用于把拷贝进度换算成真实进度）。
    private static func directoryByteSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory != true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// 递归拷贝目录：子目录建目录、符号链接原样重建、普通文件逐个拷贝，
    /// 每拷完一个文件按其字节数推进进度。
    private static func copyDirectory(from source: URL, to destination: URL, progress: Progress) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw SBError.unzipFailed(underlying: "无法枚举应用包文件")
        }
        let sourcePath = source.path
        for case let fileURL as URL in enumerator {
            let relativePath = String(fileURL.path.dropFirst(sourcePath.count + 1))
            let targetURL = destination.appendingPathComponent(relativePath)
            guard let values = try? fileURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            ) else {
                continue
            }
            if values.isSymbolicLink == true {
                let linkTarget = try fileManager.destinationOfSymbolicLink(atPath: fileURL.path)
                try fileManager.createSymbolicLink(atPath: targetURL.path, withDestinationPath: linkTarget)
            } else if values.isDirectory == true {
                try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else {
                // 父目录可能已被枚举器先建好；缺失时补建，避免拷贝失败。
                try fileManager.createDirectory(
                    at: targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                do {
                    try fileManager.copyItem(at: fileURL, to: targetURL)
                } catch {
                    throw SBError.unzipFailed(underlying: "拷贝应用文件失败")
                }
                progress.completedUnitCount += Int64(values.fileSize ?? 0)
            }
        }
    }
}
