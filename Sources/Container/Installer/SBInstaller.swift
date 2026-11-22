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
            // 0.2.17：打补丁前先读 LC_MAIN 的 entryoff——0.2.16 打过的旧文件
            // 已没有 LC_MAIN，入口偏移须先读出、存进安装记录，供加载器跳入
            // 客 main 用（见 SBGuestBootstrap）；新打补丁器（LC 原样）保留
            // LC_MAIN，读不到时记 nil，加载时回退到读文件 LC_MAIN。
            var entryOffset: UInt64? = nil
            var rawEntryOffset: UInt64 = 0
            if SBMachOEntryOffset(executablePath, &rawEntryOffset) != 0 {
                entryOffset = rawEntryOffset
            }
            // 0.2.17：打补丁改用 LiveContainer 原样代码（SBLCPatchExecutable，
            // 见 SBLCPatcher.m；LCAppInfo.m:326-340 同款调用形状）。
            // 0.2.5：段数不一致不再抛错，置标记记进安装记录（启动时 dyld 会按原文报错）。
            var segMismatch: Int32 = 0
            let patchResult = SBLCPatchExecutable(executablePath, 1, &segMismatch)
            guard patchResult == SB_LC_PATCH_OK else {
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
            // 0.2.17：全包 arm64e 修正改用 LC 原样函数
            // （LCPatchAppBundleFixupARM64eSlice，见 SBLCPatcher.m）。
            // 尽力而为：某文件失败不阻塞安装。
            SBLCFixupBundleARM64e(destinationDir.path)
            // 0.2.17：appex 也按 LC 的方法打补丁（LCPatchExecSlice，
            // doInject=false，不注入启动件；LC 的 patchGuestExtensions
            // 同款）。某 appex 打失败不阻塞安装（SB 从不加载客扩展；
            // 主程序照常装，失败记日志）。
            for appexPath in appexExecutablePaths(appPath: destinationDir.path) {
                var appexSegMismatch: Int32 = 0
                let appexPatchResult = SBLCPatchExecutable(appexPath, 0, &appexSegMismatch)
                if appexPatchResult != SB_LC_PATCH_OK {
                    SBDiagLog.log("安装 appex 打补丁失败：\(parsed.bundleID) \(appexPath) 错误码 \(appexPatchResult)（不阻塞安装）")
                }
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
                    // 0.2.17：按 LC 的重签方法（LCUtils signAppBundleWithZSign，
                    // LiveContainerSwiftUI/Utilities/LCUtils.m:143）：全包只重签
                    // 一次，bundleId 传宿主的 Bundle ID——ZSign 把它写进 CD
                    // identifier 与 designated requirement（signing.cpp:465-496、
                    // archo.cpp:329）。不再对主程序/appex 各用自己的 entitlements
                    // 再签一次（LC 不做：打过补丁的 dylib 主程序签空 entitlements；
                    // 0.2.5 的再签把带 application-identifier 的 entitlements 写进
                    // dylib，疑似 errno=1 的根因——见 build log 0.2.17）。
                    try await signApp(
                        appPath: destinationDir.path,
                        bundleID: Bundle.main.bundleIdentifier ?? "com.mjorb.sealbox",
                        certData: certData,
                        password: password,
                        progress: patchProgress
                    )
                    signed = true
                    signingCertFingerprint = certificateFingerprint(certData: certData, password: password)
                    // 0.2.17：重签后内核门（LC 的 patchExecAndSignIfNeed，
                    // LCAppInfo.m:401：签完用 checkCodeSignature 问内核签名是
                    // 否有效，无效就报签失败，不走到 dlopen 才由 dyld 报错）。
                    // 抛错后走外层 catch：signed=false，照装、标未签名。
                    guard SBLCCheckCodeSignature(executablePath) != 0 else {
                        throw SBError.signFailed(reason: "重签后内核校验不通过（F_CHECK_LV），签名未被系统接受")
                    }
                } catch {
                    // 验收 C5：签名失败也照样装，详情页标「未签名 / JIT 启动」。
                    // 0.2.10 报错日志：静默照装不行，失败原因要进诊断日志。
                    SBDiagLog.log("安装重签失败：[code=\(Self.errorCode(of: error))] \(parsed.bundleID) \(destinationDir.path) 错误：\(error.localizedDescription)（照装，标未签名）")
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
                try verifyExecutableSignature(executablePath, bundleID: parsed.bundleID, checkTeam: false)
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
            // 0.2.21：0.2.20 真机（Asspp，22:46:21.820）安装死在第三处：
            // "The file "tmp" couldn't be saved in the folder "4A8EB5AF-…""
            // ——NSCocoaErrorDomain 516（文件已存在）：containerDir/tmp 路径上
            // 已存在一个同名文件。verify 之后到 return 之间唯一的非 try? try
            // 调用就是这三处 createDirectory，前两处同父目录已成功，父目录
            // 不可能缺失；只能是目标路径上已有文件。
            // 0.2.32：0.2.21 只移走了普通文件，漏了悬空软链——0.2.31 真机
            // nread 同错 516（复用旧容器）。写链的是加载时的 applyGuestContext
            //（容器 tmp 软链 → 宿主 NSTemporaryDirectory()）；若链目标被清
            // 或自指（HOME 改写后才取 tmp，见 SBGuestBootstrap.m），链就悬空：
            // fileExists 跟链走报不存在，createDirectory 撞 EEXIST 报 516。
            // 修法：先用 destinationOfSymbolicLink 认链（只读链本身、不解析
            // 目标，悬空也能认出），软链/文件先移走再建；真目录留着（复用旧
            // 容器保留用户数据）。tmp 的软链加载时由 applyGuestContext 重建，
            // 移走无损。离线实证见 ~/workspace/tmp-sb0232verify/misc0232-verify.py
            //（悬空软链上 fileExists=false、mkdir=EEXIST、先移再建成功）。
            SBDiagLog.log("安装容器：\(parsed.bundleID) 容器UUID=\(containerUUID) 复用旧容器=\(existing != nil)")
            for relativePath in ["Documents", "Library/Caches", "tmp"] {
                let target = containerDir.appendingPathComponent(relativePath, isDirectory: true)
                if let linkDest = try? fileManager.destinationOfSymbolicLink(atPath: target.path) {
                    SBDiagLog.log("安装容器：\(parsed.bundleID) \(relativePath) 路径上是软链（→\(linkDest)），先移走再建目录")
                    try fileManager.removeItem(at: target)
                } else {
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory),
                       !isDirectory.boolValue {
                        SBDiagLog.log("安装容器：\(parsed.bundleID) \(relativePath) 路径上已有文件，先移走再建目录")
                        try fileManager.removeItem(at: target)
                    }
                }
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            }

            let keychainGroup = existing?.keychainGroup ?? allocateKeychainGroup()

            // ---- 登记入库 ----
            // 替换复用旧记录的 recordID（upsert 按 recordID 匹配，原位更新）；
            // 平行 / 全新安装用新 UUID（两条同名记录共存）。
            // 0.2.28：安装时按符号表定客 UI 类型，记入安装记录（启动分流以现算为准）。
            let uiType = SBGuestUITypeToString(SBGuestUITypeForGuestExecutable(executablePath))
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
                entryOffset: entryOffset,
                lastLaunchResult: nil,
                signingCertFingerprint: signingCertFingerprint,
                diskDirectoryName: destinationDir.lastPathComponent,
                sourceIPAFileName: parsed.sourceIPAFileName,
                uiType: uiType
            )
            SBStore.shared.upsertApp(record)

            // ---- 收尾：清替换备份（临时目录由函数入口的 defer 清理） ----
            if let backupDir = backupDir {
                try? fileManager.removeItem(at: backupDir)
            }
            // 0.2.36：安装完成记一行——0.2.35 真机 183539 进程在 Husk 分型行后
            // 15 毫秒结束，安装到底走完没有，分型行之后无任何行可证；下次再有
            // 进程在安装附近结束，先看有没有这一行。
            SBDiagLog.log("安装完成：\(parsed.bundleID) \(destinationDir.lastPathComponent) 已入库")
            // 0.2.37：重装/重导清 willConnect 拦截记录——新二进制指纹本就会让记录
            // 失效，这里再显式清一次（mtime 保留的拷贝也不再被拦），下次启动重试 willConnect。
            parsed.bundleID.withCString { SBDiagLogClearWillConnectBlockForGuest($0) }
            progress.completedUnitCount = progress.totalUnitCount
            return record
        } catch {
            // 安装失败：只清本次新建的东西，不留半截图标；
            // 替换失败时把旧包从备份处恢复原位。
            // 0.2.10 报错日志：安装链任一步失败（打补丁/重签/验签/
            // 图标/入库）都在这里记一行，含错误码与 bundle ID。
            SBDiagLog.log("安装失败：[code=\(Self.errorCode(of: error))] \(parsed.bundleID) 错误：\(error.localizedDescription)")
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
            SBDiagLog.log("重打补丁失败：\(record.bundleID) \(executablePath) 可执行文件不在磁盘")
            throw SBError.patchFailed(reason: "找不到可执行文件 \(record.executableName)")
        }
        guard let certData = certificateData(),
              let password = certificatePassword(),
              !password.isEmpty else {
            SBDiagLog.log("重打补丁失败：\(record.bundleID) \(appPath) 没有导入证书，无法重签")
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
                    SBDiagLog.log("重打补丁 Team 预检失败：\(record.bundleID) 证书 Team=\(certTeamID) 宿主 Team=\(hostTeam)（重签也换不成宿主 Team，不动手）")
                    throw SBError.teamMismatch(guestTeam: certTeamID, hostTeam: hostTeam)
                }
            } else {
                SBDiagLog.log("重打补丁 Team 预检失败：\(record.bundleID) 证书 Team=\(certTeamID) 宿主无 Team（CI 自签，无法匹配，不动手）")
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
            SBDiagLog.log("重打补丁备份失败：[code=\(Self.errorCode(of: error))] \(record.bundleID) \(executablePath) 错误：\(error.localizedDescription)")
            throw SBError.patchFailed(reason: "备份可执行文件失败")
        }
        defer { try? fileManager.removeItem(at: backupURL) }

        var segCountMismatch = record.segCountMismatch
        var signed = false
        var signingCertFingerprint: String? = nil
        // 0.2.16：entryOffset 须在 do 块之前声明——记录在 do-catch 之后
        // 重建，块内声明的变量到不了那里（同 segCountMismatch/signed 的
        // 写法；第一轮 CI 红在 470 行找不到 repatchEntryOffset）。
        var repatchEntryOffset: UInt64? = nil
        do {
            // 0.2.17：打补丁前先读 LC_MAIN 的 entryoff（同安装路径）。
            // 文件已是 0.2.16 打过的（LC_MAIN 已去掉）时读不到，用旧记录
            // 里存的值，不丢入口。
            var rawRepatchEntryOffset: UInt64 = 0
            if SBMachOEntryOffset(executablePath, &rawRepatchEntryOffset) != 0 {
                repatchEntryOffset = rawRepatchEntryOffset
            }
            var segMismatch: Int32 = 0
            let patchResult = SBLCPatchExecutable(executablePath, 1, &segMismatch)
            guard patchResult == SB_LC_PATCH_OK else {
                throw patchError(for: patchResult)
            }
            segCountMismatch = segMismatch != 0
            guard SBMachOHasIDDylib(executablePath) != 0 else {
                throw SBError.patchFailed(
                    reason: "重打补丁后仍缺少 LC_ID_DYLIB，该应用无法启动")
            }
            SBLCFixupBundleARM64e(appPath)
            // 0.2.17：appex 也按 LC 的方法打补丁（同安装路径，doInject=false）。
            for appexPath in appexExecutablePaths(appPath: appPath) {
                var appexSegMismatch: Int32 = 0
                let appexPatchResult = SBLCPatchExecutable(appexPath, 0, &appexSegMismatch)
                if appexPatchResult != SB_LC_PATCH_OK {
                    SBDiagLog.log("重打补丁 appex 打补丁失败：\(record.bundleID) \(appexPath) 错误码 \(appexPatchResult)（不阻塞重打补丁）")
                }
            }
            try Task.checkCancellation()

            // 重签（与安装同款：0.2.17 按 LC 的方法，全包只重签一次，
            // bundleId 传宿主的 Bundle ID，不再逐个 entitlements 再签）。
            try await signApp(
                appPath: appPath,
                bundleID: Bundle.main.bundleIdentifier ?? "com.mjorb.sealbox",
                certData: certData,
                password: password,
                progress: Progress(totalUnitCount: 1)
            )
            signed = true
            signingCertFingerprint = certificateFingerprint(certData: certData, password: password)
            // 0.2.17：重签后内核门（同安装路径；抛错后外层 catch 还原备份）。
            guard SBLCCheckCodeSignature(executablePath) != 0 else {
                throw SBError.signFailed(reason: "重签后内核校验不通过（F_CHECK_LV），签名未被系统接受")
            }
            // 0.2.12：重签后先单查 CMS 证书链（叶子 + WWDR 中间证书），
            // 链不全直接报原因——不要等后面的验签才含糊报错。链不全时
            // 外层 catch 会把主可执行文件还原回备份。
            let chainDetail = SBCodesignCheck.signatureDetail(atPath: executablePath)
            if !((chainDetail["cmsChainComplete"] as? NSNumber)?.boolValue ?? false) {
                let chainReason = chainDetail["cmsError"] as? String ?? "CMS 证书链不完整"
                SBDiagLog.log("重打补丁 CMS 链不完整：\(record.bundleID) \(executablePath) \(chainReason)（\(signatureDetailFields(detail: chainDetail))）")
                throw SBError.signFailed(reason: "重签后 CMS 证书链不完整：\(chainReason)")
            }
            // 0.2.7 签后验签：重签完立刻在本地验一遍主可执行文件，确认签名真能
            // 被系统接受再记 patchRevision——不要等到 dlopen 那步才由 dyld 报
            // 一个无法定位的 code signature invalid。任一失败都抛错，外层
            // catch 会把主可执行文件还原回备份（重打补丁前的状态）。
            // 0.2.8：含 Team 一致性，宿主无 Team 时也判失败（见
            // verifyExecutableSignature 注释）。
            try verifyExecutableSignature(executablePath, bundleID: record.bundleID, checkTeam: true)
        } catch {
            // 任一步失败：主可执行文件还原，记录不动。
            // 还原本身也是尽力而为：先做再记，日志里的“已还原/还原失败”
            // 按实际结果写，不许先报成功。
            var restored = false
            do {
                if fileManager.fileExists(atPath: executablePath) {
                    _ = try fileManager.replaceItemAt(
                        URL(fileURLWithPath: executablePath), withItemAt: backupURL)
                } else {
                    try fileManager.copyItem(atPath: backupURL.path, toPath: executablePath)
                }
                restored = true
            } catch {
                restored = false
            }
            // 0.2.10 报错日志：打补丁/重签/验签任一步失败都在这里记
            // 一行（错误码 + bundle ID + 路径 + 原因 + 还原结果）。
            SBDiagLog.log("重打补丁失败：[code=\(Self.errorCode(of: error))] \(record.bundleID) \(executablePath) 错误：\(error.localizedDescription)（备份\(restored ? "已还原" : "还原失败")，记录不动）")
            throw error
        }

        // 0.2.12：二进制已换，上次启动结果描述的是旧二进制——清掉 stale
        // 标记，否则下次点图标还会因“上次死在 dlopen 签名失败”强制重打
        //（每次点都重签一遍）。
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
            entryOffset: repatchEntryOffset ?? record.entryOffset,
            lastLaunchResult: nil,
            signingCertFingerprint: signingCertFingerprint,
            needsReimport: record.needsReimport,
            diskDirectoryName: record.diskDirectoryName,
            sourceIPAFileName: record.sourceIPAFileName,
            uiType: record.uiType
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
    /// 把签名逐项结果拼成日志字段（0.2.10 报错日志用）：
    /// 有效 / CMS / 页哈希（页数、首坏页）/ Team / identifier / 原因。
    static func signatureDetailFields(at path: String) -> String {
        signatureDetailFields(detail: SBCodesignCheck.signatureDetail(atPath: path))
    }

    /// 0.2.12：逐项字段扩到 CMS 全项（链、摘要、叶子到期、备用 CD、特殊槽）。
    /// 旧版只记“CMS 在位 + 页哈希”，KMusic 在 0.2.10/0.2.11 两份日志里
    /// 都没有任何逐项行——门是放行还是根本没验，无从判断。
    /// 0.2.14：再加 CMS 签名值密码学验签、Apple 9.1/9.2 属性、LC 一致性。
    static func signatureDetailFields(detail: [AnyHashable: Any]) -> String {
        let valid = (detail["valid"] as? NSNumber)?.boolValue ?? false
        let hasCMS = (detail["hasCMS"] as? NSNumber)?.boolValue ?? false
        let pageHashOK = (detail["pageHashOK"] as? NSNumber)?.boolValue ?? false
        let pageCount = (detail["pageCount"] as? NSNumber)?.intValue ?? 0
        let firstBadPage = detail["firstBadPage"] as? NSNumber
        let teamID = detail["teamID"] as? String ?? "无"
        let identifier = detail["identifier"] as? String ?? "无"
        let error = detail["error"] as? String ?? ""
        let cmsLength = (detail["cmsLength"] as? NSNumber)?.intValue ?? 0
        let cmsCertCount = (detail["cmsCertCount"] as? NSNumber)?.intValue ?? 0
        let cmsChainComplete = (detail["cmsChainComplete"] as? NSNumber)?.boolValue ?? false
        let cmsCDHashOK = (detail["cmsCDHashOK"] as? NSNumber)?.boolValue ?? false
        let cmsLeafCN = detail["cmsLeafCN"] as? String ?? "无"
        let cmsIntermediateCN = detail["cmsIntermediateCN"] as? String ?? "无"
        let cmsLeafExpiry = detail["cmsLeafExpiry"] as? String ?? "无"
        let cmsLeafExpired = (detail["cmsLeafExpired"] as? NSNumber)?.boolValue ?? false
        let cmsError = detail["cmsError"] as? String ?? ""
        let cmsSignatureValid = (detail["cmsSignatureValid"] as? NSNumber)?.boolValue ?? false
        let cmsSignatureError = detail["cmsSignatureError"] as? String ?? ""
        let cmsAppleAttrsValid = (detail["cmsAppleAttrsValid"] as? NSNumber)?.boolValue ?? false
        let cmsAppleAttrsError = detail["cmsAppleAttrsError"] as? String ?? ""
        let lcSignatureOK = (detail["lcSignatureOK"] as? NSNumber)?.boolValue ?? false
        let lcDataOff = (detail["lcDataOff"] as? NSNumber)?.intValue ?? 0
        let lcDataSize = (detail["lcDataSize"] as? NSNumber)?.intValue ?? 0
        let superblobLength = (detail["superblobLength"] as? NSNumber)?.intValue ?? 0
        // 0.2.15：CD 与 Mach-O 头字段——逐项全过仍被 dyld 拒绝时，这些是与签名无关的证据。
        let cdVersion = (detail["cdVersion"] as? NSNumber)?.intValue ?? 0
        let cdFlags = (detail["cdFlags"] as? NSNumber)?.intValue ?? 0
        let cdExecSegFlags = (detail["cdExecSegFlags"] as? NSNumber)?.uint64Value ?? 0
        let cdExecSegLimit = (detail["cdExecSegLimit"] as? NSNumber)?.uint64Value ?? 0
        let cdCodeLimit = (detail["cdCodeLimit"] as? NSNumber)?.intValue ?? 0
        let cdHashType = (detail["cdHashType"] as? NSNumber)?.intValue ?? 0
        let cdPageSizeLog2 = (detail["cdPageSizeLog2"] as? NSNumber)?.intValue ?? 0
        let cdExecSegOK = (detail["cdExecSegOK"] as? NSNumber)?.boolValue ?? false
        let fileType = (detail["fileType"] as? NSNumber)?.intValue ?? 0
        let cryptid = (detail["cryptid"] as? NSNumber)?.intValue ?? 0
        let hasLCMain = (detail["hasLCMain"] as? NSNumber)?.boolValue ?? false
        let lcMainOK = (detail["lcMainOK"] as? NSNumber)?.boolValue ?? false
        // 0.2.16：结构解析失败时各逐项字段全是缺省值（lcMainOK 缺省 NO），
        // 不能把“没读到”标成“不相容”误导诊断——只在解析成功时标注。
        let structureOK = (detail["structureOK"] as? NSNumber)?.boolValue ?? false
        let idDylibName = detail["idDylibName"] as? String ?? ""
        let hasAltCD = (detail["hasAltCD"] as? NSNumber)?.boolValue ?? false
        let altPageHashOK = (detail["altPageHashOK"] as? NSNumber)?.boolValue ?? true
        let altFirstBadPage = detail["altFirstBadPage"] as? NSNumber
        let specialSlotsOK = (detail["specialSlotsOK"] as? NSNumber)?.boolValue ?? false
        let badSpecialSlot = detail["badSpecialSlot"] as? NSNumber
        var fields = "签名逐项：有效=\(valid ? "是" : "否") CMS=\(hasCMS ? "在位" : "缺失") 页哈希=\(pageHashOK ? "全过" : "不过")(\(pageCount)页"
        if let bad = firstBadPage {
            fields += " 首坏页=\(bad.intValue)"
        }
        fields += ") Team=\(teamID) identifier=\(identifier)"
        if hasCMS {
            fields += " CMS链=\(cmsChainComplete ? "完整" : "不完整")(\(cmsCertCount)张 \(cmsLength)字节) CMS摘要=\(cmsCDHashOK ? "对上" : "不对") 叶子=\(cmsLeafCN)(到期\(cmsLeafExpiry)\(cmsLeafExpired ? " 已过期" : "")) 中间=\(cmsIntermediateCN) CMS验签=\(cmsSignatureValid ? "通过" : "不过") Apple属性=\(cmsAppleAttrsValid ? "对上" : "不对")"
        }
        fields += hasAltCD ? " 备用CD=\(altPageHashOK ? "全过" : "不过")" : " 备用CD=无"
        if let bad = altFirstBadPage {
            fields += "(首坏页=\(bad.intValue))"
        }
        fields += " 特殊槽=\(specialSlotsOK ? "全过" : "不过")"
        if let slot = badSpecialSlot {
            fields += "(坏槽=\(slot.intValue))"
        }
        fields += " LC=\(lcSignatureOK ? "一致" : "不一致")(off=0x\(String(lcDataOff, radix: 16)) size=0x\(String(lcDataSize, radix: 16)) superblob=0x\(String(superblobLength, radix: 16)))"
        let fileTypeName: String
        switch fileType {
        case 2: fileTypeName = "MH_EXECUTE"
        case 6: fileTypeName = "MH_DYLIB"
        case 8: fileTypeName = "MH_BUNDLE"
        default: fileTypeName = "0x\(String(fileType, radix: 16))"
        }
        fields += " CD[ver=0x\(String(cdVersion, radix: 16)) flags=0x\(String(cdFlags, radix: 16)) execSegFlags=0x\(String(cdExecSegFlags, radix: 16))\(cdExecSegOK ? "" : " 不相容") execSegLimit=0x\(String(cdExecSegLimit, radix: 16)) 限=0x\(String(cdCodeLimit, radix: 16)) sha\(cdHashType == 2 ? "256" : "1") 页2^\(cdPageSizeLog2)] 文件=\(fileTypeName) 加密=\(cryptid) LC_MAIN=\(hasLCMain ? "在" : "无")\((lcMainOK || !structureOK) ? "" : " 不相容") ID=\(idDylibName.isEmpty ? "无" : idDylibName)"
        if !cmsSignatureError.isEmpty {
            fields += " CMS验签原因：\(cmsSignatureError)"
        } else if !cmsAppleAttrsError.isEmpty {
            fields += " Apple属性原因：\(cmsAppleAttrsError)"
        } else if !cmsError.isEmpty {
            fields += " CMS原因：\(cmsError)"
        } else if !error.isEmpty {
            fields += " 原因：\(error)"
        }
        return fields
    }

    /// 0.2.12：把 signatureDetail 字典翻成“哪一项坏”的清单，供修复门
    /// 抛错时点名——不许再只报一句“验签失败”就走到 dlopen 去撞墙。
    /// CMS 的具体坏因由 ObjC 的 cmsError 给（解析失败 / 链不完整都带原因），
    /// 这里不再另拼一个含糊的“链不完整”。
    static func failingSignatureItems(detail: [AnyHashable: Any]) -> [String] {
        var items: [String] = []
        if (detail["valid"] as? NSNumber)?.boolValue ?? false {
            return items
        }
        if !((detail["structureOK"] as? NSNumber)?.boolValue ?? false) {
            // superblob / 主 CD 解析就失败：逐项字段全是缺省值，点名没意义，
            // 只报结构原因。
            let error = detail["error"] as? String ?? "签名结构无效"
            return ["签名结构无效：\(error)"]
        }
        let cmsError = detail["cmsError"] as? String ?? ""
        if !((detail["hasCMS"] as? NSNumber)?.boolValue ?? false) {
            items.append("缺 CMS 签名块")
        } else if ((detail["cmsLength"] as? NSNumber)?.intValue ?? 0) <= 0 {
            items.append("CMS 签名块为空")
        } else if !cmsError.isEmpty {
            items.append("CMS：\(cmsError)")
        }
        if (detail["cmsLeafExpired"] as? NSNumber)?.boolValue ?? false {
            items.append("叶子证书已过期（到期 \(detail["cmsLeafExpiry"] as? String ?? "")）")
        }
        if (detail["hasCMS"] as? NSNumber)?.boolValue ?? false,
           ((detail["cmsLength"] as? NSNumber)?.intValue ?? 0) > 0,
           cmsError.isEmpty,
           !((detail["cmsCDHashOK"] as? NSNumber)?.boolValue ?? false) {
            items.append("CMS 摘要与 CodeDirectory 对不上（签名后文件被改过）")
        }
        // 0.2.14：CMS 签名值密码学验签与 Apple 属性比对的坏项——逐项全过
        // 仍被 dyld 拒绝时，这两项是唯一能点名的证据。
        if (detail["hasCMS"] as? NSNumber)?.boolValue ?? false,
           ((detail["cmsLength"] as? NSNumber)?.intValue ?? 0) > 0,
           !((detail["cmsSignatureValid"] as? NSNumber)?.boolValue ?? false) {
            let reason = detail["cmsSignatureError"] as? String ?? "CMS 签名值验签不过"
            items.append("CMS 签名值验签不过：\(reason)")
        }
        if (detail["hasCMS"] as? NSNumber)?.boolValue ?? false,
           ((detail["cmsLength"] as? NSNumber)?.intValue ?? 0) > 0,
           !((detail["cmsAppleAttrsValid"] as? NSNumber)?.boolValue ?? false) {
            let reason = detail["cmsAppleAttrsError"] as? String ?? "Apple 9.1/9.2 属性与 CodeDirectory 对不上"
            items.append("Apple 签名属性不对：\(reason)")
        }
        if !((detail["lcSignatureOK"] as? NSNumber)?.boolValue ?? false) {
            items.append("LC_CODE_SIGNATURE 与 superblob 长度对不上，或 CMS 槽超出 superblob")
        }
        // 0.2.15：CD execSeg 相容性——不是签名项，是 CD 可用性：dylib 的 CD
        // 带 MAIN_BINARY 时签名逐项全过、内核照样在 mmap 时拒收，须重签
        // （重签用修好的 ZSign，dylib 的 execSegFlags 会写 0）。
        if !((detail["cdExecSegOK"] as? NSNumber)?.boolValue ?? false) {
            let flags = (detail["cdExecSegFlags"] as? NSNumber)?.uint64Value ?? 0
            let ft = (detail["fileType"] as? NSNumber)?.intValue ?? 0
            let ftName = ft == 2 ? "MH_EXECUTE" : ft == 6 ? "MH_DYLIB" : ft == 8 ? "MH_BUNDLE" : "0x\(String(ft, radix: 16))"
            items.append("CD 声明自己是主程序（execSegFlags=0x\(String(flags, radix: 16)) 含 MAIN_BINARY），但文件是 \(ftName)，内核不认这种签名，须重签")
        }
        // 0.2.17：LC_MAIN 不再是不合格项——LC 的打补丁器保留 LC_MAIN
        // （0.2.16“dylib 带 LC_MAIN 即无法加载”的理论已被 0.2.16 真机
        // 日志证伪：LC_MAIN=无仍 errno=1；而 LC 自己的客 dylib 都带
        // LC_MAIN）。诊断串里仍显示 LC_MAIN 在/无（signatureDetailFields），
        // 但不再进 failing 清单。
        if !((detail["pageHashOK"] as? NSNumber)?.boolValue ?? false) {
            if let bad = detail["firstBadPage"] as? NSNumber {
                items.append("第 \(bad.intValue) 页内容哈希与签名不符")
            } else {
                items.append("页哈希不过")
            }
        }
        if (detail["hasAltCD"] as? NSNumber)?.boolValue ?? false,
           !((detail["altPageHashOK"] as? NSNumber)?.boolValue ?? false) {
            if let bad = detail["altFirstBadPage"] as? NSNumber {
                items.append("备用 CodeDirectory 第 \(bad.intValue) 页内容哈希不符")
            } else {
                items.append("备用 CodeDirectory 页哈希不过")
            }
        }
        if !((detail["specialSlotsOK"] as? NSNumber)?.boolValue ?? false) {
            if let slot = detail["badSpecialSlot"] as? NSNumber {
                items.append("特殊槽 \(slot.intValue) 哈希与签名不符")
            } else {
                items.append("特殊槽哈希不符")
            }
        }
        if items.isEmpty {
            items.append("签名逐项不合格（原因未知）")
        }
        return items
    }

    static func failingSignatureItems(at path: String) -> [String] {
        failingSignatureItems(detail: SBCodesignCheck.signatureDetail(atPath: path))
    }

    /// 只抛错、不静默：调用方在 do 块内，抛错会走 catch 还原备份。
    static func verifyExecutableSignature(_ executablePath: String, bundleID: String, checkTeam: Bool = false) throws {
        let detail = signatureDetailFields(at: executablePath)
        do {
            // ObjC 的 validateSignatureAtPath:error: 在 Swift 侧以 throws
            // 形式导入；失败时 error 即校验原因。
            try SBCodesignCheck.validateSignature(atPath: executablePath)
        } catch {
            let sbError = SBError.signFailed(
                reason: "验签失败：\(error.localizedDescription)"
            )
            SBDiagLog.log("验签失败：[code=\(sbError.code)] \(bundleID) \(executablePath) \(detail)")
            throw sbError
        }
        SBDiagLog.log("验签通过：\(bundleID) \(executablePath) \(detail)")
        if checkTeam {
            try checkTeamMatch(executablePath, bundleID: bundleID)
        }
    }

    /// 0.2.8：只比 Team（不验结构）。客 Team 与宿主 Team 不一致时抛
    /// teamMismatch；客无 Team 时不抛（无 Team 可比）。
    static func checkTeamMatch(_ executablePath: String, bundleID: String) throws {
        let guestTeam = SBCodesignCheck.teamIdentifier(atPath: executablePath)
        guard let guestTeam = guestTeam else { return }
        let hostExecutablePath = Bundle.main.executableURL?.path
        let hostTeam = hostExecutablePath.flatMap { SBCodesignCheck.teamIdentifier(atPath: $0) }
        NSLog("[SBInstaller] checkTeamMatch: guestTeam=%@ hostTeam=%@",
              guestTeam, hostTeam ?? "(nil)")
        if let hostTeam = hostTeam {
            if guestTeam != hostTeam {
                // 0.2.10 报错日志：之前只有 NSLog，不进诊断日志文件。
                SBDiagLog.log("Team 不一致：\(bundleID) \(executablePath) 客 Team=\(guestTeam) 宿主 Team=\(hostTeam)（dyld 要求一致，须用同一证书重签宿主）")
                throw SBError.teamMismatch(guestTeam: guestTeam, hostTeam: hostTeam)
            }
            // 0.2.11：通过时也记一行（客 Team 与宿主 Team 的值）——只记
            // “验签通过”分不清门是放行还是根本没比 Team。
            SBDiagLog.log("Team 一致：\(bundleID) 客 Team=\(guestTeam) 宿主 Team=\(hostTeam)")
        } else {
            SBDiagLog.log("Team 预检：\(bundleID) \(executablePath) 客 Team=\(guestTeam) 宿主无 Team（CI 自签，dyld 不会放行，须用同一证书重签宿主）")
            throw SBError.teamMismatch(guestTeam: guestTeam, hostTeam: nil)
        }
    }

    /// 点图标时修复门能否动手重打补丁：p12 文件在且钥匙串密码非空
    ///（与 SBCertificate.hasCertificate 同条件；门本身不依赖证书也能验）。
    private static var canRepair: Bool {
        guard let data = certificateData(), !data.isEmpty,
              let password = certificatePassword(), !password.isEmpty else {
            return false
        }
        return true
    }

    /// 0.2.39：点图标前的签名门改成 LiveContainer 的走法（LCAppInfo.m:302-431
    /// patchExecAndSignIfNeed），只认内核验签，不再自建多道门。
    /// LC 的顺序：补丁版本门（launchApp 里已做，patchRevision < 当前值时重打）
    /// → 无证书/32 位/不签名时跳过 → 内核 checkCodeSignature 有效即放行 →
    /// 无效时须有证书，ZSign 整包重签 → 再问内核，仍无效即报错。
    /// 本函数是 LC 那一段的映射：
    /// - 静态逐项（SBCodesignCheck）与叶子指纹只记诊断行，不再决定放行/重签。
    ///   0.2.38 的叶子比对触发重签已删：LC 安装时签名、点开时不重签；旧叶子
    ///   客能不能开由内核说了算——内核拒才重签，内核认就直接开。0.2.37 的
    ///   旧叶子 dlopen 死因若真是内核拒，内核门同样会触发重签（0.2.21 曾
    ///   实证内核门比静态逐项严：注入件静态全过、内核门 EPERM 拒过）；
    ///   若内核认而 dlopen 仍死，那是内核门与 dlopen 不一致的新证据，
    ///   由 lastLaunchSigFailed 标记兜底（见下），不是叶子比对能证明的事。
    /// - Team 不再单独拦：LC 没有 Team 门；重签后 repatchInstalledApp 内
    ///   仍有证书 Team 预检 + verifyExecutableSignature(checkTeam: true)。
    /// - 保留的两处 SealBox 专属守卫（LC 没有，但有真机依据）：
    ///   ① 缺 LC_ID_DYLIB → 重打补丁：注入件是 SealBox 的加载方式，
    ///   LC 的 dontInjectTweakLoader 是受支持的模式，我们的注入件丢了
    ///   客就裸跑（环境/伪装全无），不能放行；
    ///   ② 上次启动实测死在 dlopen 签名失败（lastLaunchSigFailed，须容器
    ///   一致）而内核本次说有效 → 重签一次：静态与 dlopen 不一致已有
    ///   0.2.37 真机实证，内核与 dlopen 也可能不一致；只在实测失败后触发，
    ///   0.2.26 D 护栏（连续修 2 次即停）仍防循环。
    /// - 注入件先修分支已删：launchApp 在门通过后仍调 ensureHooksDylibSigned，
    ///   门里不再抢修一次。
    /// - 0.2.26 A 不变：任一成功返回前清掉 lastLaunchResult 并落盘。
    /// 0.2.26 A：修后清标记——任一成功返回前，清掉记录的
    /// lastLaunchResult 并 upsert 落盘。0.2.25 的无限循环就是 hooks
    /// 分支修好后直接 return record、不清标记、不落盘导致的：下次预检
    /// 又见同一标记、再修复、再重启。repatch 路径已在返回的记录里清
    /// （lastLaunchResult: nil），这里只补两条直接返回的路；记录里本就
    /// 没有标记时是空操作，不多写一次盘。
    /// （0.2.39 补回：B 重写本函数时误删了该 helper 定义，首轮 CI 报
    /// cannot find 'clearedSignatureFailure' in scope，run 44967429305。）
    private static func clearedSignatureFailure(_ record: SBInstalledApp) -> SBInstalledApp {
        guard record.lastLaunchResult != nil else { return record }
        var updated = record
        updated.lastLaunchResult = nil
        SBStore.shared.upsertApp(updated)
        SBDiagLog.log("签名修复门：\(record.bundleID) 修后清除上次签名失败标记")
        return updated
    }

    static func ensureLaunchableSignature(_ record: SBInstalledApp) async throws -> SBInstalledApp {
        let executablePath = record.executableURL.path
        let gateDetail = SBCodesignCheck.signatureDetail(atPath: executablePath)
        let lastLaunchSigFailed = record.lastLaunchSigFailed
        SBDiagLog.log("签名修复门验签：\(record.bundleID) \(executablePath) \(signatureDetailFields(detail: gateDetail)) 上次签名失败标记=\(lastLaunchSigFailed ? "是" : "否")\(record.lastLaunchResult.map { "（\($0.message.prefix(80))）" } ?? "")")
        // 叶子指纹只记诊断（0.2.39：触发重签已删，见函数头注释）。
        // 0.2.40：解析失败也记一行，不再静默跳过；解析器所有失败只返回 nil，
        // 诊断调用绝不许再崩进程（0.2.39 Guoguo/Husk 即死在这两行之后）。
        if let currentFingerprint = currentCertificateLeafFingerprint() {
            if let guestFingerprint = guestLeafFingerprint(atPath: executablePath) {
                let guestExpiry = gateDetail["cmsLeafExpiry"] as? String ?? "未知"
                SBDiagLog.log("签名修复门：\(record.bundleID) 客叶子=\(guestFingerprint.prefix(12)) 到期\(guestExpiry)，当前证书叶子=\(currentFingerprint.prefix(12))（仅诊断，不触发重签）")
            } else {
                SBDiagLog.log("签名修复门：\(record.bundleID) 客叶子解析失败（仅诊断）")
            }
        }
        // LC 的判定（LCAppInfo.m:377-390）：直接问内核。
        var kernelStep: Int32 = 0
        var kernelErrno: Int32 = 0
        var kernelMessage = [CChar](repeating: 0, count: 512)
        let kernelValid = kernelMessage.withUnsafeMutableBufferPointer { msgPtr in
            SBLCCheckCodeSignatureDetail(executablePath, &kernelStep, &kernelErrno, msgPtr.baseAddress, msgPtr.count) != 0
        }
        let kernelMessageText = kernelMessage.withUnsafeBufferPointer { buf in
            buf.baseAddress.map { String(cString: $0) } ?? ""
        }
        SBDiagLog.log("签名修复门内核验签：\(record.bundleID) \(executablePath) 内核验签=\(kernelValid ? "通过" : "不通过")（步骤=\(kernelStep)，errno=\(kernelErrno)\(kernelMessageText.isEmpty ? "" : "，内核原话：\(kernelMessageText)")")
        if kernelValid && !lastLaunchSigFailed {
            // 内核认 + 上次没死在签名上 → 放行（LC 的 return YES）。
            // 缺 LC_ID_DYLIB 是 SealBox 专属守卫（见函数头注释①）。
            if SBMachOHasIDDylib(executablePath) == 0 {
                guard canRepair else {
                    throw SBError.patchFailed(reason: "缺少 LC_ID_DYLIB，且未导入证书，无法重打补丁修复")
                }
                SBDiagLog.log("签名修复门：\(record.bundleID) \(executablePath) 内核验签通过但缺 LC_ID_DYLIB，走重打补丁")
                return try await repatchInstalledApp(record)
            }
            return clearedSignatureFailure(record)
        }
        // 内核不认，或上次实测死在 dlopen 签名失败（守卫②）：重签。
        // 无证书时只拦不修（LC：noCertificateFoundErr）。
        let reason: String
        if !kernelValid {
            reason = "内核验签不通过（步骤=\(kernelStep)，errno=\(kernelErrno)\(kernelMessageText.isEmpty ? "" : "，\(kernelMessageText)")"
        } else {
            reason = "上次启动死在 dlopen 签名失败（code signature invalid），内核本次虽通过仍重签一次"
        }
        guard canRepair else {
            throw SBError.signFailed(reason: "\(reason)，且未导入证书，无法重签修复")
        }
        SBDiagLog.log("签名修复门：\(record.bundleID) \(executablePath) 强制重打补丁+重签（\(reason)）")
        let repaired = try await repatchInstalledApp(record)
        // repatchInstalledApp 内已做重签后内核复验（不通过即抛错还原备份），
        // 这里不再重复跑逐项复验。重签后叶子复验也不再做——判定权在内核。
        return repaired
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

    /// 报错日志字段（0.2.10）：SBError 的稳定数字码；非 SBError 的
    /// 系统错误记 -1（日志里同时有错误原文，不丢信息）。
    static func errorCode(of error: Error) -> Int {
        (error as? SBError)?.code ?? -1
    }

    private static func patchError(for code: Int32) -> SBError {
        switch code {
        case SB_LC_PATCH_ERR_ENCRYPTED:
            return .encryptedIPA
        case SB_LC_PATCH_ERR_UNSUPPORTED_32BIT:
            return .patchFailed(reason: "该应用为 32 位应用，无法在不开启 JIT 的情况下运行")
        case SB_LC_PATCH_ERR_NO_SPACE:
            return .patchFailed(reason: "可执行文件内没有足够空间注入启动组件")
        case SB_LC_PATCH_ERR_UNSUPPORTED_ARCH:
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

    // MARK: - 0.2.38：客可执行文件的叶子指纹（CMS DER 解析）

    /// 0.2.38：修复门必须把客叶子指纹与当前证书叶子指纹比对——SecStaticCode
    /// 系 API 是 macOS-only，iOS 上没有（见 SBCodesignCheck.h），只能像
    /// SBCodesignCheck 那样手动解析 Mach-O＋superblob＋CMS DER。下面是它的
    /// Swift 侧镜像：同样的常量（LC_CODE_SIGNATURE 0x1d、superblob magic
    /// 0xfade0cc0、CMS 槽 0x10000、BlobWrapper 头 8 字节）、同样的 DER 读法
    /// （SBDerReadTLV／SBDerChildren）、同样的证书解析（SBParseCert：TBS
    /// 字段顺序严格校验）与同样的叶子判定（主体不等于任何其他证书签发者的
    /// 那张，且唯一；自签单证书时叶子就是它自己）。
    /// 只取叶子身份（issuer／subject TLV＋整张证书 DER），不验链、不验签名值——
    /// 链与签名值的校验仍由 SBCodesignCheck 的逐项负责；这里只回答“这张叶子
    /// 是不是当前证书的那张”。任一步解析失败返回 nil（调用方跳过本项比对，
    /// 不因算不出而误拦）。

    /// DER TLV（起止均为在整个 Data 里的偏移）。
    private struct SBDerTLV {
        var tag: UInt8
        var contentStart: Int
        var contentLen: Int
        var totalLen: Int
        /// 标签头长（不定长 TLV 的 totalLen 含尾部 EOC 2 字节，不能从
        /// totalLen - contentLen 反推——0.2.40 修：那样会把起点算早 2 字节）。
        var headerLen: Int
        /// TLV 起点（含标签头）＝内容起点－头长。
        var start: Int { contentStart - headerLen }
        var end: Int { start + totalLen }
    }

    /// 读一个 TLV（SBDerReadTLV 同款：多字节标签不支持；不定长 0x80 扫子项
    /// 到 EOC；长形式长度 1–4 字节；嵌套深度 ≤16）。
    /// 0.2.40：下标一律按 data 的下标域（startIndex/endIndex）检查，不再
    /// 只比 count——Data 切片保留基下标，count 够不等于 data[0] 合法。
    private static func derReadTLV(_ data: Data, at offset: Int, depth: Int) -> SBDerTLV? {
        guard depth <= 16 else { return nil }
        guard offset >= 0, data.startIndex + offset + 2 <= data.endIndex else { return nil }
        let tag = data[data.startIndex + offset]
        guard tag != 0x1F else { return nil }
        let lenByte = data[data.startIndex + offset + 1]
        var headerLen = 2
        var contentLen = 0
        if lenByte == 0x80 {
            var p = offset + headerLen
            while true {
                guard p + 2 <= data.endIndex - data.startIndex else { return nil }
                if data[data.startIndex + p] == 0x00 && data[data.startIndex + p + 1] == 0x00 {
                    contentLen = p - (offset + headerLen)
                    return SBDerTLV(tag: tag, contentStart: offset + headerLen,
                                    contentLen: contentLen, totalLen: (p + 2) - offset,
                                    headerLen: headerLen)
                }
                guard let child = derReadTLV(data, at: p, depth: depth + 1) else { return nil }
                p += child.totalLen
            }
        } else if lenByte & 0x80 != 0 {
            let n = Int(lenByte & 0x7F)
            guard n >= 1 && n <= 4 && offset + 2 + n <= data.endIndex - data.startIndex else { return nil }
            for i in 0..<n {
                contentLen = (contentLen << 8) | Int(data[data.startIndex + offset + 2 + i])
            }
            headerLen = 2 + n
        } else {
            contentLen = Int(lenByte)
        }
        guard offset + headerLen + contentLen <= data.endIndex - data.startIndex else { return nil }
        return SBDerTLV(tag: tag, contentStart: offset + headerLen,
                        contentLen: contentLen, totalLen: headerLen + contentLen,
                        headerLen: headerLen)
    }

    /// 列出一个构造型 TLV 的全部子项（必须恰好在内容尾结束；子项 ≤16，
    /// SBDerMaxChildren 同款）。
    private static func derChildren(_ data: Data, of parent: SBDerTLV, depth: Int) -> [SBDerTLV]? {
        var items: [SBDerTLV] = []
        var p = parent.contentStart
        let end = parent.contentStart + parent.contentLen
        while p < end {
            guard let child = derReadTLV(data, at: p, depth: depth + 1) else { return nil }
            items.append(child)
            guard items.count <= 16 else { return nil }
            p += child.totalLen
        }
        guard p == end else { return nil }
        return items
    }

    /// 一张 CMS 证书里叶子判定要用的三段 DER 范围（SBParseCert 同款字段）。
    private struct SBCMSCert {
        var certRange: Range<Int>
        var issuerRange: Range<Int>
        var subjectRange: Range<Int>
    }

    /// 解析一张证书（SBParseCert 同款：TBS 字段顺序严格校验
    /// serial／signature／issuer／validity／subject，validity 两时间标签须是
    /// UTCTime／GeneralizedTime；只取 issuer／subject 完整 TLV，不取 CN）。
    private static func parseCMSCert(_ certTLV: SBDerTLV, in data: Data) -> SBCMSCert? {
        guard certTLV.tag == 0x30 else { return nil }
        guard let kids = derChildren(data, of: certTLV, depth: 0),
              !kids.isEmpty, kids[0].tag == 0x30 else { return nil }
        guard let tbs = derChildren(data, of: kids[0], depth: 0) else { return nil }
        var idx = 0
        if idx < tbs.count && tbs[idx].tag == 0xA0 { idx += 1 }
        let expected: [UInt8] = [0x02, 0x30, 0x30, 0x30, 0x30]
        for k in 0..<5 {
            guard idx + k < tbs.count, tbs[idx + k].tag == expected[k],
                  tbs[idx + k].contentLen > 0 else { return nil }
        }
        let issuer = tbs[idx + 2]
        let validity = tbs[idx + 3]
        let subject = tbs[idx + 4]
        guard let times = derChildren(data, of: validity, depth: 0), times.count >= 2,
              (times[0].tag == 0x17 || times[0].tag == 0x18),
              (times[1].tag == 0x17 || times[1].tag == 0x18) else { return nil }
        return SBCMSCert(
            certRange: certTLV.start..<(certTLV.start + certTLV.totalLen),
            issuerRange: issuer.start..<issuer.end,
            subjectRange: subject.start..<subject.end)
    }

    /// CMS DER（BlobWrapper 头已去掉）→ 叶子证书 DER 的 SHA-256 hex。
    /// ContentInfo SEQ{OID, [0] SignedData} → SignedData SEQ{version,
    /// digestAlgorithms SET, contentInfo SEQ, [0] 证书集…}；取第一个证书集
    /// （SBCodesignCheck 同款：certCount == 0 时才取），叶子判定同款规则。
    private static func cmsLeafFingerprint(_ cmsDER: Data) -> String? {
        guard let top = derReadTLV(cmsDER, at: 0, depth: 0), top.tag == 0x30 else { return nil }
        guard let ci = derChildren(cmsDER, of: top, depth: 0), ci.count >= 2,
              ci[0].tag == 0x06, ci[1].tag == 0xA0 else { return nil }
        guard let sdWrap = derChildren(cmsDER, of: ci[1], depth: 0),
              !sdWrap.isEmpty, sdWrap[0].tag == 0x30 else { return nil }
        guard let sd = derChildren(cmsDER, of: sdWrap[0], depth: 0), sd.count >= 3,
              sd[0].tag == 0x02, sd[1].tag == 0x31, sd[2].tag == 0x30 else { return nil }
        var certs: [SBCMSCert] = []
        for i in 3..<sd.count where sd[i].tag == 0xA0 {
            guard let certKids = derChildren(cmsDER, of: sd[i], depth: 0) else { return nil }
            for kid in certKids {
                guard certs.count < 8, let cert = parseCMSCert(kid, in: cmsDER) else { return nil }
                certs.append(cert)
            }
            break
        }
        guard !certs.isEmpty else { return nil }
        var leafIdx = -1
        for i in certs.indices {
            let subject = cmsDER[certs[i].subjectRange]
            var isIssuerOfAnother = false
            for j in certs.indices where j != i {
                if subject == cmsDER[certs[j].issuerRange] {
                    isIssuerOfAnother = true
                    break
                }
            }
            if !isIssuerOfAnother {
                guard leafIdx < 0 else { return nil }
                leafIdx = i
            }
        }
        guard leafIdx >= 0 else { return nil }
        let leafDER = cmsDER[certs[leafIdx].certRange]
        let digest = SHA256.hash(data: leafDER)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func be32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0 && data.startIndex + offset + 4 <= data.endIndex else { return nil }
        return (UInt32(data[data.startIndex + offset]) << 24) | (UInt32(data[data.startIndex + offset + 1]) << 16)
            | (UInt32(data[data.startIndex + offset + 2]) << 8) | UInt32(data[data.startIndex + offset + 3])
    }

    private static func le32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0 && data.startIndex + offset + 4 <= data.endIndex else { return nil }
        return UInt32(data[data.startIndex + offset]) | (UInt32(data[data.startIndex + offset + 1]) << 8)
            | (UInt32(data[data.startIndex + offset + 2]) << 16) | (UInt32(data[data.startIndex + offset + 3]) << 24)
    }

    /// 客可执行文件 → CMS 叶子证书 DER 的 SHA-256 hex（与 certificateFingerprint
    /// 同款算法，可直接比对）。Mach-O 定位同款 SBCodesignCheck.SBFindSignature
    /// （fat 取 arm64 slice；thin 须是 MH_MAGIC_64；LC_CODE_SIGNATURE 给签名区），
    /// superblob 定位同款 SBParseSignature（magic 0xfade0cc0；索引里找 CMS 槽
    /// 0x10000；CMS blob 长度含 8 字节 BlobWrapper 头，DER 从槽偏移＋8 起）。
    /// 无签名、无 CMS 槽、解析失败都返回 nil。
    private static func guestLeafFingerprint(atPath path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count >= 4 else { return nil }
        var sliceBase = 0
        var sliceLen = data.count
        let magicLE = le32(data, at: 0) ?? 0
        if magicLE == 0xBEBAFECA || magicLE == 0xCAFEBABE {
            guard let nfat = be32(data, at: 4) else { return nil }
            var found = false
            for i in 0..<Int(nfat) {
                let arch = 8 + i * 20
                guard arch + 20 <= data.count,
                      let cputype = be32(data, at: arch),
                      let offset = be32(data, at: arch + 8),
                      let size = be32(data, at: arch + 12) else { return nil }
                if cputype == 0x0100000C {
                    guard Int(offset) + Int(size) <= data.count else { return nil }
                    sliceBase = Int(offset)
                    sliceLen = Int(size)
                    found = true
                    break
                }
            }
            guard found else { return nil }
        } else if magicLE != 0xFEEDFACF {
            return nil
        }
        guard sliceLen >= 32, let ncmds = le32(data, at: sliceBase + 16) else { return nil }
        var lc = sliceBase + 32
        var sigOff = 0
        var sigSize = 0
        var foundSig = false
        for _ in 0..<Int(ncmds) {
            guard lc + 8 <= sliceBase + sliceLen,
                  let cmd = le32(data, at: lc),
                  let cmdsize = le32(data, at: lc + 4),
                  cmdsize >= 8, lc + Int(cmdsize) <= sliceBase + sliceLen else { return nil }
            if cmd == 0x1D {
                guard cmdsize >= 16,
                      let dataoff = le32(data, at: lc + 8),
                      let datasize = le32(data, at: lc + 12),
                      dataoff != 0, datasize != 0,
                      Int(dataoff) + Int(datasize) <= sliceLen else { return nil }
                sigOff = Int(dataoff)
                sigSize = Int(datasize)
                foundSig = true
            }
            lc += Int(cmdsize)
        }
        guard foundSig else { return nil }
        let sigBase = sliceBase + sigOff
        guard sigSize >= 12,
              let sigMagic = be32(data, at: sigBase), sigMagic == 0xFADE0CC0,
              let blobLength = be32(data, at: sigBase + 4),
              let count = be32(data, at: sigBase + 8),
              blobLength <= sigSize, 12 + Int(count) * 8 <= sigSize else { return nil }
        var cmsOffset = 0
        var cmsBlobLength = 0
        var foundCMS = false
        for i in 0..<Int(count) {
            let entry = sigBase + 12 + i * 8
            guard let type = be32(data, at: entry),
                  let offset = be32(data, at: entry + 4),
                  Int(offset) < sigSize else { return nil }
            if type == 0x10000 {
                cmsOffset = Int(offset)
                guard let len = be32(data, at: sigBase + cmsOffset + 4) else { return nil }
                cmsBlobLength = Int(len)
                foundCMS = true
                break
            }
        }
        guard foundCMS, cmsBlobLength >= 8 else { return nil }
        let derLen = cmsBlobLength - 8
        guard derLen > 0, cmsOffset + 8 + derLen <= sigSize else { return nil }
        // 0.2.40 根治：Data 切片保留基下标（Husk 合法下标约 1370 万起），
        // 下游解析器第一行 data[0] 即陷阱。Data(...) 拷贝一次把 startIndex
        // 归零，下游全部 0 起下标一次合法；不要逐处改下标。
        let cmsDER = Data(data[(sigBase + cmsOffset + 8)..<(sigBase + cmsOffset + 8 + derLen)])
        return cmsLeafFingerprint(cmsDER)
    }

    /// 当前已导入证书的叶子指纹（与安装时记的 signingCertFingerprint 同款算法）。
    /// 无证书／口令错／p12 读不出时返回 nil。
    private static func currentCertificateLeafFingerprint() -> String? {
        guard let certData = certificateData(),
              let password = certificatePassword(), !password.isEmpty else { return nil }
        return certificateFingerprint(certData: certData, password: password)
    }

    /// 调 ObjC++ 包装 `SBSigner` 对整个 .app 重签；失败抛 `SBError.signFailed`。
    /// 0.2.14：重签前先验私钥与叶子证书匹配——安装、重打补丁、appex 再签
    /// 都走这里，一处拦住全部；不匹配直接报，不许用错 key 签出坏 CMS。
    private static func signApp(
        appPath: String,
        bundleID: String,
        certData: Data,
        password: String,
        progress: Progress
    ) async throws {
        if SBCertificate.privateKeyMatchesCertificate(data: certData, password: password) == false {
            SBDiagLog.log("重签失败：\(bundleID) \(appPath) 证书与私钥不匹配，请重新导入")
            throw SBError.signFailed(reason: "证书与私钥不匹配，请重新导入")
        }
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

    /// 收集 PlugIns 下各 appex 的可执行文件路径（0.2.17，LC 的
    /// patchGuestExtensions 同款枚举）：读 appex 自身 Info.plist 的
    /// CFBundleExecutable；只取路径（不再取 entitlements——0.2.17 起
    /// appex 与主程序一样只打补丁、不逐个 entitlements 再签）。
    private static func appexExecutablePaths(appPath: String) -> [String] {
        let fileManager = FileManager.default
        let pluginsDir = URL(fileURLWithPath: appPath).appendingPathComponent("PlugIns")
        guard let appexURLs = try? fileManager.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var paths: [String] = []
        for appexURL in appexURLs where appexURL.pathExtension == "appex" {
            guard let plist = NSDictionary(
                contentsOf: appexURL.appendingPathComponent("Info.plist")),
                  let executableName = plist["CFBundleExecutable"] as? String,
                  !executableName.isEmpty else {
                continue
            }
            let executablePath = appexURL.appendingPathComponent(executableName).path
            guard fileManager.fileExists(atPath: executablePath) else {
                continue
            }
            paths.append(executablePath)
        }
        return paths
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
