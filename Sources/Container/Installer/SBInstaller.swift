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
            // 0.2.5：段数不一致不再抛错，置标记记进安装记录（启动时 dyld 会按原文报错）。
            var segMismatch: Int32 = 0
            let patchResult = SBMachOPatchExecutable(executablePath, hooksDylibPath, &segMismatch)
            guard patchResult == SB_MACHO_PATCH_OK else {
                throw patchError(for: patchResult)
            }
            let segCountMismatch = segMismatch != 0
            // 0.2.6：打补丁后必须校验 LC_ID_DYLIB 在位——打补丁器在空间实在不够时
            // 是静默跳过 LC_ID_DYLIB 的（与 LC 一致），缺了它 dlopen 必败
            //（0.2.5 真机：pip_swift 已是 MH_DYLIB 但缺 LC_ID_DYLIB）。
            // 装一个注定打不开的包不如安装时直接报错。
            guard SBMachOHasIDDylib(executablePath) != 0 else {
                throw SBError.patchFailed(
                    reason: "可执行文件没有足够空间插入 LC_ID_DYLIB，装了也打不开")
            }
            // 0.2.5：全包 arm64e 修正——包内 .dylib 与 framework 可执行文件补
            // LIB64 标记（LiveContainer 的 LCPatchAppBundleFixupARM64eSlice 同款做法）。
            // 尽力而为：某文件失败不阻塞安装。
            fixupBundleARM64e(appPath: destinationDir.path)
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
                    // 0.2.5：先取各可执行文件的 entitlements（从原包签名提取、Team
                    // 前缀换成导入证书的 Team；读不到时合成最小项），再全包重签，
                    // 最后主程序与 appex 各用自己的 entitlements 再签一次。
                    // 提取必须在全包重签之前——重签会覆盖原签名，之后就读不到了。
                    // 打补丁不碰签名区，提取放在打补丁之后仍能读到原签名。
                    // Team 取不到时跳过这一步（只全包重签，与 0.2.4 行为一致）。
                    var executablesToResign: [(path: String, bundleID: String, entitlements: String)] = []
                    if let teamID = SBSigner.teamID(withCertData: certData, password: password) {
                        if let mainEntitlements = SBGuestEntitlementsForExecutableAtPath(
                            executablePath, teamID, parsed.bundleID) {
                            executablesToResign.append(
                                (path: executablePath, bundleID: parsed.bundleID,
                                 entitlements: mainEntitlements))
                        }
                        executablesToResign.append(
                            contentsOf: appexExecutablesToResign(
                                appPath: destinationDir.path, teamID: teamID))
                    }
                    try await signApp(
                        appPath: destinationDir.path,
                        bundleID: parsed.bundleID,
                        certData: certData,
                        password: password,
                        progress: patchProgress
                    )
                    signed = true
                    signingCertFingerprint = certificateFingerprint(certData: certData, password: password)
                    // 主程序与 appex 用各自的 entitlements 再签一次（0.2.5）。
                    // 某一次失败不阻塞安装：该文件保留全包重签的签名（空 entitlements），
                    // 与 0.2.4 行为一致。
                    for entry in executablesToResign {
                        try? await signMachOWithEntitlements(
                            path: entry.path,
                            bundleID: entry.bundleID,
                            certData: certData,
                            password: password,
                            entitlementXML: entry.entitlements
                        )
                    }
                } catch {
                    // 验收 C5：签名失败也照样装，详情页标「未签名 / JIT 启动」。
                    signed = false
                }
            }
            // 0.2.8：安装时验签——签完立刻在本地验一遍主可执行文件，确认
            // 签名真能被系统接受再入库。0.2.7 的验签只接了重打补丁路径，
            // 安装路径没有；Via 就是 0.2.5 安装时签了名、记录写 signed=true，
            // 点图标才由 dlopen 报 code signature invalid。
            // 只验结构（页哈希 + CMS 块存在），不验 Team：Team 是宿主与
            // 客应用的配对属性，是部署问题不是签名缺陷；在安装时按 Team
            // 拦会把所有应用都挡在门外（当前宿主是 CI 自签、无 Team），
            // Team 的诊断放在启动时（ensureLaunchableSignature）。
            // 验签失败直接抛错，安装失败清理，不留签坏的包。
            if signed {
                try verifyExecutableSignature(executablePath, checkTeam: false)
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
                segCountMismatch: segCountMismatch,
                lastLaunchResult: nil,
                signingCertFingerprint: signingCertFingerprint,
                diskDirectoryName: destinationDir.lastPathComponent,
                sourceIPAFileName: parsed.sourceIPAFileName
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

    // MARK: - 已装应用重打补丁（0.2.6）

    /// 给已装应用重新打补丁 + 重签（0.2.6，修 0.2.5 真机报的
    /// "MH_DYLIB is missing LC_ID_DYLIB"）。
    ///
    /// 根因：0.2.4 及更早的打补丁器只改 filetype，不插 LC_ID_DYLIB；0.2.5 的
    /// 新打补丁器只在新安装时跑。`SBConstants.patchRevision` 从 1 升到 2 时
    /// 没有任何接线让已装应用重打补丁——`patchRevision` 只写不读。
    /// 于是 0.2.4 或更早装的包一直带着无 LC_ID_DYLIB 的 MH_DYLIB，
    /// 0.2.5 上点图标 dlopen 必败。
    ///
    /// 做法：用当前打补丁器对主可执行文件再打一次（已打过的内容会跳过，
    /// 幂等）、校验 LC_ID_DYLIB 在位、全包 arm64e 修正、再用导入证书全包
    /// 重签 + 主程序 / appex 各用自己的 entitlements 再签一次（与安装
    /// 同款）。成功后把记录的 patchRevision 升到当前值并入库。
    ///
    /// 失败时把主可执行文件从备份还原（打补丁改过的文件原样还原），
    /// 记录不动，调用方按错误提示用户，不启动。
    /// - Returns: 更新后的安装记录。
    static func repatchInstalledApp(_ record: SBInstalledApp) async throws -> SBInstalledApp {
        let fileManager = FileManager.default
        let appPath = record.bundleURL.path
        let executablePath = record.executableURL.path
        guard fileManager.fileExists(atPath: executablePath) else {
            throw SBError.patchFailed(reason: "找不到可执行文件 \(record.executableName)")
        }
        guard let certData = certificateData(),
              let password = certificatePassword(),
              !password.isEmpty else {
            throw SBError.signFailed(reason: "没有导入证书，无法重签")
        }
        // 0.2.8：重打补丁前先比 Team——重签只能把客 Team 换成当前证书的
        // Team，换不了宿主的 Team。当前证书 Team 与宿主 Team 不一致时，
        // 重打一整套也修不好，先报出来，不白做工、不碰文件。
        // 当前证书读不到 Team 时不拦（无法判断时让后面的验签决定）。
        if let certTeamID = SBSigner.teamID(withCertData: certData, password: password) {
            // 注意：不能写 Bundle.main.executableURL?.path.flatMap{...}——
            // 可选链只解第一层，后面的 .flatMap 会落在非可选 String 上
            // （按字符迭代），$0 就成了 Character。先绑到 String? 再 flatMap。
            let hostExecutablePath = Bundle.main.executableURL?.path
            let hostTeam = hostExecutablePath.flatMap {
                SBCodesignCheck.teamIdentifier(atPath: $0)
            }
            if let hostTeam = hostTeam {
                if certTeamID != hostTeam {
                    throw SBError.teamMismatch(guestTeam: certTeamID, hostTeam: hostTeam)
                }
            } else {
                throw SBError.teamMismatch(guestTeam: certTeamID, hostTeam: nil)
            }
        }
        // 先备份主可执行文件：打补丁会使原签名失效，之后任一步失败都把
        // 备份还原，应用回到重打补丁前的状态（而不是留一个签坏的包）。
        let backupURL = fileManager.temporaryDirectory
            .appendingPathComponent("SBRepatchBackup-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(atPath: executablePath, toPath: backupURL.path)
        } catch {
            throw SBError.patchFailed(reason: "备份可执行文件失败")
        }
        defer { try? fileManager.removeItem(at: backupURL) }

        var segCountMismatch = record.segCountMismatch
        var signed = false
        var signingCertFingerprint: String? = nil
        do {
            let hooksDylibPath = "@loader_path/../../Tweaks/\(SBConstants.guestHooksDylibName)"
            var segMismatch: Int32 = 0
            let patchResult = SBMachOPatchExecutable(executablePath, hooksDylibPath, &segMismatch)
            guard patchResult == SB_MACHO_PATCH_OK else {
                throw patchError(for: patchResult)
            }
            segCountMismatch = segMismatch != 0
            guard SBMachOHasIDDylib(executablePath) != 0 else {
                throw SBError.patchFailed(
                    reason: "重打补丁后仍缺少 LC_ID_DYLIB，该应用无法启动")
            }
            fixupBundleARM64e(appPath: appPath)
            try Task.checkCancellation()

            // 重签（与安装同款：先取各可执行文件的 entitlements，再全包重签，
            // 最后主程序与 appex 各用自己的 entitlements 再签一次）。
            var executablesToResign: [(path: String, bundleID: String, entitlements: String)] = []
            if let teamID = SBSigner.teamID(withCertData: certData, password: password) {
                if let mainEntitlements = SBGuestEntitlementsForExecutableAtPath(
                    executablePath, teamID, record.bundleID) {
                    executablesToResign.append(
                        (path: executablePath, bundleID: record.bundleID,
                         entitlements: mainEntitlements))
                }
                executablesToResign.append(
                    contentsOf: appexExecutablesToResign(appPath: appPath, teamID: teamID))
            }
            try await signApp(
                appPath: appPath,
                bundleID: record.bundleID,
                certData: certData,
                password: password,
                progress: Progress(totalUnitCount: 1)
            )
            signed = true
            signingCertFingerprint = certificateFingerprint(certData: certData, password: password)
            for entry in executablesToResign {
                try? await signMachOWithEntitlements(
                    path: entry.path,
                    bundleID: entry.bundleID,
                    certData: certData,
                    password: password,
                    entitlementXML: entry.entitlements
                )
            }
            // 0.2.7 签后验签：重签完立刻在本地验一遍主可执行文件，确认签名真能
            // 被系统接受再记 patchRevision——不要等到 dlopen 那步才由 dyld 报
            // 一个无法定位的 code signature invalid。任一失败都抛错，外层
            // catch 会把主可执行文件还原回备份（重打补丁前的状态）。
            // 0.2.8：含 Team 一致性，宿主无 Team 时也判失败（见
            // verifyExecutableSignature 注释）。
            try verifyExecutableSignature(executablePath, checkTeam: true)
        } catch {
            // 任一步失败：主可执行文件还原，记录不动。
            if fileManager.fileExists(atPath: executablePath) {
                _ = try? fileManager.replaceItemAt(
                    URL(fileURLWithPath: executablePath), withItemAt: backupURL)
            } else {
                try? fileManager.copyItem(atPath: backupURL.path, toPath: executablePath)
            }
            throw error
        }

        let updated = SBInstalledApp(
            recordID: record.recordID,
            bundleID: record.bundleID,
            displayName: record.displayName,
            version: record.version,
            shortVersion: record.shortVersion,
            executableName: record.executableName,
            containerUUID: record.containerUUID,
            keychainGroup: record.keychainGroup,
            installedDate: record.installedDate,
            patchRevision: SBConstants.patchRevision,
            signed: signed,
            needsJIT: record.needsJIT,
            segCountMismatch: segCountMismatch,
            lastLaunchResult: record.lastLaunchResult,
            signingCertFingerprint: signingCertFingerprint,
            needsReimport: record.needsReimport,
            diskDirectoryName: record.diskDirectoryName,
            sourceIPAFileName: record.sourceIPAFileName
        )
        SBStore.shared.upsertApp(updated)
        return updated
    }

    /// 0.2.8 签名验签核心（安装、重打补丁、启动前三条线共用）。
    /// ① 结构校验（SBCodesignCheck）：superblob/CodeDirectory 可解析、每页
    /// 内容哈希与 CodeDirectory 一致、CMS 签名块存在。任一不过，dyld 在
    /// dlopen 时一定报 code signature invalid——签名在结构上就是坏的。
    /// ② Team 一致（checkTeam 为 true 时）：客主程序的 Team 必须与宿主进程
    /// 的 Team 一致，否则 dyld 的 Library Validation（F_CHECK_LV）拒绝
    /// 加载。0.2.7 的“宿主无 Team 就跳过”是错的，已纠正：0.2.1 自测已
    /// 证实，宿主 CI 自签无 Team、测试件用导入证书签（Team Wan、CMS 在位）
    /// 仍被 dlopen 以 code signature invalid 拒绝（errno=1）——无 Team 的
    /// 宿主不是“不校验”，而是没有任何 Team 能与客应用匹配。
    /// 客本身无 Team 时跳过 Team 项（无 Team 可比；adhoc/未签名件走 JIT 门）。
    /// 安装时不验 Team（checkTeam: false）：Team 是宿主与客应用的配对属性，
    /// 是部署问题不是签名缺陷；在安装时按 Team 拦会把所有应用都挡在门外。
    /// 只抛错、不静默：调用方在 do 块内，抛错会走 catch 还原备份。
    static func verifyExecutableSignature(_ executablePath: String, checkTeam: Bool) throws {
        do {
            // ObjC 的 validateSignatureAtPath:error: 在 Swift 侧以 throws
            // 形式导入；失败时 error 即校验原因。
            try SBCodesignCheck.validateSignature(atPath: executablePath)
        } catch {
            throw SBError.signFailed(
                reason: "验签失败：\(error.localizedDescription)"
            )
        }
        if checkTeam {
            try checkTeamMatch(executablePath)
        }
    }

    /// 0.2.8：只比 Team（不验结构）。客 Team 与宿主 Team 不一致时抛
    /// teamMismatch；客无 Team 时不抛（无 Team 可比）。
    static func checkTeamMatch(_ executablePath: String) throws {
        let guestTeam = SBCodesignCheck.teamIdentifier(atPath: executablePath)
        guard let guestTeam = guestTeam else { return }
        let hostExecutablePath = Bundle.main.executableURL?.path
        let hostTeam = hostExecutablePath.flatMap { SBCodesignCheck.teamIdentifier(atPath: $0) }
        NSLog("[SBInstaller] checkTeamMatch: guestTeam=%@ hostTeam=%@",
              guestTeam, hostTeam ?? "(nil)")
        if let hostTeam = hostTeam {
            if guestTeam != hostTeam {
                throw SBError.teamMismatch(guestTeam: guestTeam, hostTeam: hostTeam)
            }
        } else {
            throw SBError.teamMismatch(guestTeam: guestTeam, hostTeam: nil)
        }
    }

    /// 0.2.8：点图标前的签名修复门（Via 案：patchRevision 已是当前值，
    /// 但安装时签的名是坏的——0.2.5 安装走 ZSign 时签名结构有问题，
    /// 记录却写 signed=true；点图标直接启动，dlopen 才报 code signature
    /// invalid）。
    /// - 先验签：结构/CMS 坏 → 走 repatchInstalledApp 修一次（重打补丁+
    ///   重签+验签）；修不好抛错，不启动。
    /// - Team 不一致 → 也走 repatchInstalledApp 修一次：repatch 前会先
    ///   比当前证书 Team 与宿主 Team——重签能把客 Team 换成当前证书的
    ///   Team，换完能与宿主匹配才动手；换完也匹配不上直接抛 teamMismatch，
    ///   不白做工。
    /// - LC_ID_DYLIB 缺失 → 走 repatchInstalledApp（补 ID）。
    /// - 全过 → 原样返回，不动记录。
    /// 调用方须保证已导入证书（点图标时 coordinator 已做 hasCertificate
    /// 门控）。
    static func ensureLaunchableSignature(_ record: SBInstalledApp) async throws -> SBInstalledApp {
        let executablePath = record.executableURL.path
        if SBMachOHasIDDylib(executablePath) == 0 {
            NSLog("[SBInstaller] ensureLaunchableSignature: %@ 缺 LC_ID_DYLIB，走重打补丁", record.bundleID)
            return try await repatchInstalledApp(record)
        }
        do {
            try verifyExecutableSignature(executablePath, checkTeam: true)
            return record
        } catch {
            NSLog("[SBInstaller] ensureLaunchableSignature: %@ 验签失败（%@），走重打补丁修复",
                  record.bundleID, error.localizedDescription)
            return try await repatchInstalledApp(record)
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

    /// 对单个 Mach-O 用给定 entitlements 再签一次（0.2.5）；失败抛 `SBError.signFailed`。
    private static func signMachOWithEntitlements(
        path: String,
        bundleID: String,
        certData: Data,
        password: String,
        entitlementXML: String
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            SBSigner.signMachO(
                atPath: path,
                bundleID: bundleID,
                certData: certData,
                password: password,
                entitlementXML: entitlementXML
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

    /// 全包 arm64e 修正（0.2.5，LiveContainer 的 LCPatchAppBundleFixupARM64eSlice
    /// 同款做法）：包内 .dylib 与 framework 可执行文件补 CPU_SUBTYPE_LIB64 标记。
    /// 主可执行文件已由 SBMachOPatchExecutable 处理过，不在这里重复。
    /// 尽力而为：某文件读失败 / 不是 Mach-O 时跳过，不阻塞安装。
    private static func fixupBundleARM64e(appPath: String) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: appPath),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]) else {
                continue
            }
            if values.isDirectory == true {
                // framework：读 Info.plist 的 CFBundleExecutable，找不到时用
                // framework 名（去 .framework 后缀）作可执行文件名。
                guard fileURL.pathExtension == "framework" else {
                    continue
                }
                let executableName: String
                if let plist = NSDictionary(
                    contentsOf: fileURL.appendingPathComponent("Info.plist")),
                   let name = plist["CFBundleExecutable"] as? String, !name.isEmpty {
                    executableName = name
                } else {
                    executableName = fileURL.deletingPathExtension().lastPathComponent
                }
                let executablePath = fileURL.appendingPathComponent(executableName).path
                if fileManager.fileExists(atPath: executablePath) {
                    _ = SBMachOPatchARM64eFile(executablePath)
                }
            } else if fileURL.pathExtension == "dylib" {
                _ = SBMachOPatchARM64eFile(fileURL.path)
            }
        }
    }

    /// 收集 PlugIns 下各 appex 的重签信息（0.2.5）：读 appex 自身 Info.plist 的
    /// CFBundleExecutable 与 CFBundleIdentifier，取原包 entitlements（Team 前缀
    /// 已换成导入证书的 Team；读不到时合成最小项）。framework / dylib 不需要
    /// entitlements，不在这里出现。SB 从不加载客扩展，appex 只签、不打补丁。
    private static func appexExecutablesToResign(
        appPath: String,
        teamID: String
    ) -> [(path: String, bundleID: String, entitlements: String)] {
        let fileManager = FileManager.default
        let pluginsDir = URL(fileURLWithPath: appPath).appendingPathComponent("PlugIns")
        guard let appexURLs = try? fileManager.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var entries: [(path: String, bundleID: String, entitlements: String)] = []
        for appexURL in appexURLs where appexURL.pathExtension == "appex" {
            guard let plist = NSDictionary(
                contentsOf: appexURL.appendingPathComponent("Info.plist")),
                  let executableName = plist["CFBundleExecutable"] as? String,
                  !executableName.isEmpty,
                  let appexBundleID = plist["CFBundleIdentifier"] as? String,
                  !appexBundleID.isEmpty else {
                continue
            }
            let executablePath = appexURL.appendingPathComponent(executableName).path
            guard fileManager.fileExists(atPath: executablePath),
                  let entitlements = SBGuestEntitlementsForExecutableAtPath(
                    executablePath, teamID, appexBundleID) else {
                continue
            }
            entries.append((path: executablePath, bundleID: appexBundleID,
                            entitlements: entitlements))
        }
        return entries
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
