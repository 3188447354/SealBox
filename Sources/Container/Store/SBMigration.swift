// SBMigration.swift — 0.1.6 已装记录迁移（设计 §1.5）。
//
// 旧记录在标准 UserDefaults，键 `vm.installedApps`，模型只有名字 / 版本 /
// 文件名 / 分类四字段（壳子 VMState.InstalledApp），没有 Bundle ID、没有
// 容器 UUID、没有钥匙串组、没有签名状态，不能直接复用。
//
// 迁移做法：逐条取 Documents/IPAs 里的原始 IPA 文件重新跑 SBIPAParser.parse：
// - 解析成功 → 按 §1.5 建新记录（容器 UUID 与钥匙串组新分配，installedDate 取
//   IPA 文件修改时间，signed=false）。迁移只建记录，不自动跑安装管线；
//   包缺失时启动链路按设计走“找不到安装包，请重新安装”分支。
// - 解析失败（文件没了、不是 IPA、读不到 Bundle ID）→ 建 needsReimport=true
//   的占位记录：bundleID / executableName / diskDirectoryName 均为空串
//   （未知，不编造），displayName / version 用旧记录的值，keychainGroup 为 -1
//   （未分配）。不编造任何字段，不静默丢弃任何一条旧记录。
//
// 旧记录只读不删（非破坏性，留作回滚）。App Group UserDefaults 键
// `SBMigrationCompleted` 记一次迁移完成，跑过一次不再重复跑；已迁移过的
// 记录按 bundleID + fileName 去重，不再重复建。
//
// 入口只实现、不接线：步骤 8 接线时在启动时调用本方法。

import Foundation

/// 旧记录迁移。
enum SBMigration {

    private static let completedKey = "SBMigrationCompleted"
    private static let migratedFilesKey = "SBMigrationMigratedFileNames"
    private static let legacyInstalledAppsKey = "vm.installedApps"

    /// 壳子旧记录的形状（VMState.InstalledApp：name / version / fileName /
    /// category）。这里自带一份解码结构，不依赖壳子模型。
    private struct LegacyInstalledApp: Codable {
        var name: String
        var version: String
        var fileName: String
        var category: String
    }

    /// 跑一次迁移（幂等）。重解析涉及解压，耗时工作放后台线程做，
    /// 调用方在主线程调本方法即可。
    static func migrateIfNeeded() async {
        await Task.detached(priority: .userInitiated) {
            runMigration()
        }.value
    }

    private static func runMigration() {
        guard let appGroupDefaults = UserDefaults(suiteName: SBConstants.appGroupSuiteName) else {
            return
        }
        // 跑过一次不再重复跑。
        if appGroupDefaults.bool(forKey: completedKey) {
            SBDiagLog.log("迁移已完成过，跳过")
            return
        }

        guard let data = UserDefaults.standard.data(forKey: legacyInstalledAppsKey),
              let legacyApps = try? JSONDecoder().decode([LegacyInstalledApp].self, from: data),
              !legacyApps.isEmpty else {
            // 旧记录为空（或读不到）：直接记完成，不做任何事。
            appGroupDefaults.set(true, forKey: completedKey)
            return
        }

        let fileManager = FileManager.default
        let ipasDir = SBConstants.documentsURL.appendingPathComponent("IPAs", isDirectory: true)

        var migratedKeys = Set(appGroupDefaults.stringArray(forKey: migratedFilesKey) ?? [])
        var seenThisRun = Set<String>()
        var usedGroups = Set(SBStore.shared.loadInstalledApps().map { $0.keychainGroup })
        var newRecords: [SBInstalledApp] = []

        for legacy in legacyApps {
            let ipaURL = ipasDir.appendingPathComponent(legacy.fileName)
            // installedDate 取 IPA 文件修改时间；文件没了则取当前时间
            // （占位记录的必填时间戳，不是编造的业务字段）。
            let installedDate: Date
            if let attributes = try? fileManager.attributesOfItem(atPath: ipaURL.path),
               let modificationDate = attributes[.modificationDate] as? Date {
                installedDate = modificationDate
            } else {
                installedDate = Date()
            }

            if let parsed = try? SBIPAParser.parse(ipaURL: ipaURL) {
                // 解析成功：按 §1.5 建新记录，容器 UUID 与钥匙串组新分配。
                let dedupeKey = "\(parsed.bundleID)|\(legacy.fileName)"
                if migratedKeys.contains(dedupeKey) || seenThisRun.contains(dedupeKey) {
                    continue
                }
                seenThisRun.insert(dedupeKey)
                migratedKeys.insert(dedupeKey)
                let record = SBInstalledApp(
                    bundleID: parsed.bundleID,
                    displayName: parsed.displayName,
                    version: parsed.version,
                    shortVersion: parsed.version,
                    executableName: parsed.executableName,
                    containerUUID: UUID().uuidString,
                    keychainGroup: allocateKeychainGroup(usedGroups: &usedGroups),
                    installedDate: installedDate,
                    signed: false,
                    needsJIT: false,
                    diskDirectoryName: nil,
                    sourceIPAFileName: legacy.fileName
                )
                newRecords.append(record)
            } else {
                // 解析失败：建 needsReimport 占位记录，不编造任何字段。
                // bundleID 未知记空串（注释写明），keychainGroup -1 表示未分配。
                let dedupeKey = "|\(legacy.fileName)"
                if migratedKeys.contains(dedupeKey) || seenThisRun.contains(dedupeKey) {
                    continue
                }
                seenThisRun.insert(dedupeKey)
                migratedKeys.insert(dedupeKey)
                let record = SBInstalledApp(
                    bundleID: "",
                    displayName: legacy.name,
                    version: legacy.version,
                    shortVersion: legacy.version,
                    executableName: "",
                    containerUUID: UUID().uuidString,
                    keychainGroup: -1,
                    installedDate: installedDate,
                    signed: false,
                    needsJIT: false,
                    needsReimport: true,
                    diskDirectoryName: "",
                    sourceIPAFileName: legacy.fileName
                )
                newRecords.append(record)
            }
        }

        if !newRecords.isEmpty {
            var apps = SBStore.shared.loadInstalledApps()
            apps.append(contentsOf: newRecords)
            SBStore.shared.saveInstalledApps(apps)
        }
        SBDiagLog.log("迁移解析完成，新建 \(newRecords.count) 条记录")
        appGroupDefaults.set(Array(migratedKeys), forKey: migratedFilesKey)
        appGroupDefaults.set(true, forKey: completedKey)
    }

    /// 在 0..<128 里挑一个未被占用的钥匙串组；128 组全满时随机复用一组
    /// （与 SBInstaller.allocateKeychainGroup 同一规则）。
    private static func allocateKeychainGroup(usedGroups: inout Set<Int>) -> Int {
        let count = SBConstants.keychainGroupCount
        guard count > 0 else { return 0 }
        if let free = (0..<count).first(where: { !usedGroups.contains($0) }) {
            usedGroups.insert(free)
            return free
        }
        let reused = Int.random(in: 0..<count)
        usedGroups.insert(reused)
        return reused
    }
}
