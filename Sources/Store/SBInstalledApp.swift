import Foundation

/// 一次启动的结果（成功或失败），记在详情页“上次启动结果”里。
struct SBLaunchResult: Codable {
    var success: Bool
    var date: Date
    var message: String
}

/// 已安装的客 App（元数据存在 App Group UserDefaults 的 SBInstalledApps 里；
/// bundle 本体在 Documents/Applications/<bundleID>.app，数据容器在
/// Documents/Data/Application/<containerUUID>/）。
struct SBInstalledApp: Codable, Identifiable, Equatable {
    var id: String { bundleID }

    var bundleID: String
    var displayName: String
    var version: String
    var shortVersion: String
    var executableName: String
    var containerUUID: String
    var keychainGroup: Int
    var installedDate: Date
    var patchRevision: Int
    var signed: Bool
    var needsJIT: Bool
    var lastLaunchResult: SBLaunchResult?

    /// 磁盘上的 bundle 目录名。平行安装时加时间戳后缀，与 bundleID 区分。
    var diskDirectoryName: String

    init(bundleID: String,
         displayName: String,
         version: String,
         shortVersion: String,
         executableName: String,
         containerUUID: String,
         keychainGroup: Int,
         installedDate: Date = Date(),
         patchRevision: Int = SBConstants.patchRevision,
         signed: Bool,
         needsJIT: Bool = false,
         lastLaunchResult: SBLaunchResult? = nil,
         diskDirectoryName: String? = nil) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.version = version
        self.shortVersion = shortVersion
        self.executableName = executableName
        self.containerUUID = containerUUID
        self.keychainGroup = keychainGroup
        self.installedDate = installedDate
        self.patchRevision = patchRevision
        self.signed = signed
        self.needsJIT = needsJIT
        self.lastLaunchResult = lastLaunchResult
        self.diskDirectoryName = diskDirectoryName ?? (bundleID + ".app")
    }

    var bundleURL: URL {
        SBConstants.documentsURL
            .appendingPathComponent(SBConstants.guestAppsDirectoryName)
            .appendingPathComponent(diskDirectoryName)
    }

    var executableURL: URL {
        bundleURL.appendingPathComponent(executableName)
    }

    var dataContainerURL: URL {
        SBConstants.guestDataContainerURL(
            containerUUID: containerUUID, documentsURL: SBConstants.documentsURL)
    }

    var iconURL: URL {
        bundleURL.appendingPathComponent("SBIcon.png")
    }
}

/// 启动收据：点图标后写下，宿主重起后兑现；客加载失败时靠它区分
/// “重起请求丢了”还是“客加载失败了”。
struct SBLaunchReceipt: Codable {
    var requestID: String
    var guestBundleID: String
    var containerUUID: String
    /// restart-requested（已发请求）→ restart-confirmed（新进程已启动）
    /// → guest-loaded（已进客 App，可清除）/ guest-failed（客加载失败）
    var stage: String
    var createdAt: Date
    var stageDetail: String?

    static func requested(guestBundleID: String, containerUUID: String) -> SBLaunchReceipt {
        SBLaunchReceipt(
            requestID: UUID().uuidString,
            guestBundleID: guestBundleID,
            containerUUID: containerUUID,
            stage: "restart-requested",
            createdAt: Date(),
            stageDetail: nil)
    }
}
