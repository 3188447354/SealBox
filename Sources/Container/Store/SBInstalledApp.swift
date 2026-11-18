import Foundation

/// 一次启动的结果（成功或失败），记在详情页“上次启动结果”里。
struct SBLaunchResult: Codable, Equatable {
    var success: Bool
    var date: Date
    var message: String
}

/// 已安装的客 App（元数据存在 App Group UserDefaults 的 SBInstalledApps 里；
/// bundle 本体在 Documents/Applications/<bundleID>.app，数据容器在
/// Documents/Data/Application/<containerUUID>/）。
///
/// 记录主键是 `recordID`（UUID），不是 Bundle ID：平行安装的两条同名记录必须
/// 共存，0.1.0 用 Bundle ID 作 id 时桌面只显示首条（v1 已知限制）。
struct SBInstalledApp: Codable, Identifiable, Equatable {
    /// 记录主键。旧记录（无此键）解码时现场生成一个新 UUID，不丢记录。
    var recordID: UUID

    var id: UUID { recordID }

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

    /// 安装时所用证书的 SHA-256 指纹（SecCertificateCopyData 后取 SHA-256 hex）；
    /// 未签名安装时为 nil。证书更换后靠它判断是否需要重签（设计 §4.7）。
    var signingCertFingerprint: String?

    /// 迁移失败标记：旧记录重解析失败时建的占位记录，bundleID / executableName /
    /// diskDirectoryName 均为空串（不编造），桌面显示灰色、点开只给重新导入 / 删除。
    var needsReimport: Bool

    /// 磁盘上的 bundle 目录名。平行安装时加时间戳后缀，与 bundleID 区分。
    var diskDirectoryName: String

    /// 原始 IPA 在 Documents/IPAs 下的文件名（重装/重新导入的源文件）；
    /// 旧记录（无此键）解码时为 nil，不编造。
    var sourceIPAFileName: String?

    init(recordID: UUID = UUID(),
         bundleID: String,
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
         signingCertFingerprint: String? = nil,
         needsReimport: Bool = false,
         diskDirectoryName: String? = nil,
         sourceIPAFileName: String? = nil) {
        self.recordID = recordID
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
        self.signingCertFingerprint = signingCertFingerprint
        self.needsReimport = needsReimport
        self.diskDirectoryName = diskDirectoryName ?? (bundleID + ".app")
        self.sourceIPAFileName = sourceIPAFileName
    }

    enum CodingKeys: String, CodingKey {
        case recordID, bundleID, displayName, version, shortVersion
        case executableName, containerUUID, keychainGroup, installedDate
        case patchRevision, signed, needsJIT, lastLaunchResult
        case signingCertFingerprint, needsReimport, diskDirectoryName
        case sourceIPAFileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 新字段用 decodeIfPresent 兜底：旧收据 / 旧记录没有这些键时不丢整条记录。
        recordID = try container.decodeIfPresent(UUID.self, forKey: .recordID) ?? UUID()
        bundleID = try container.decode(String.self, forKey: .bundleID)
        displayName = try container.decode(String.self, forKey: .displayName)
        version = try container.decode(String.self, forKey: .version)
        shortVersion = try container.decode(String.self, forKey: .shortVersion)
        executableName = try container.decode(String.self, forKey: .executableName)
        containerUUID = try container.decode(String.self, forKey: .containerUUID)
        keychainGroup = try container.decode(Int.self, forKey: .keychainGroup)
        installedDate = try container.decode(Date.self, forKey: .installedDate)
        patchRevision = try container.decode(Int.self, forKey: .patchRevision)
        signed = try container.decode(Bool.self, forKey: .signed)
        needsJIT = try container.decode(Bool.self, forKey: .needsJIT)
        lastLaunchResult = try container.decodeIfPresent(SBLaunchResult.self, forKey: .lastLaunchResult)
        signingCertFingerprint = try container.decodeIfPresent(String.self, forKey: .signingCertFingerprint)
        needsReimport = try container.decodeIfPresent(Bool.self, forKey: .needsReimport) ?? false
        diskDirectoryName = try container.decode(String.self, forKey: .diskDirectoryName)
        sourceIPAFileName = try container.decodeIfPresent(String.self, forKey: .sourceIPAFileName)
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
/// 收据由 ObjC 侧（SBGuestLoader）写 JSON，Swift 侧只读；diskDirectoryName 与
/// keychainGroup 由启动请求方写入，缺失时按缺省处理（平行安装的目录名、
/// 钥匙串组号都靠这两个字段带到新进程）。
struct SBLaunchReceipt: Codable {
    var requestID: String
    var guestBundleID: String
    var containerUUID: String
    /// 客 App 在磁盘上的目录名（平行安装带时间戳后缀）。
    var diskDirectoryName: String
    /// 该客 App 的钥匙串组号（0..<128）；-1 表示未知，按容器 UUID 哈希兜底。
    var keychainGroup: Int
    /// restart-requested（已发请求）→ restart-confirmed（新进程已启动）
    /// → guest-loaded（已进客 App，可清除）/ guest-failed（客加载失败）
    var stage: String
    var createdAt: Date
    var stageDetail: String?

    enum CodingKeys: String, CodingKey {
        case requestID, guestBundleID, containerUUID
        case diskDirectoryName, keychainGroup
        case stage, createdAt, stageDetail
    }

    init(requestID: String, guestBundleID: String, containerUUID: String,
         diskDirectoryName: String, keychainGroup: Int,
         stage: String, createdAt: Date, stageDetail: String?) {
        self.requestID = requestID
        self.guestBundleID = guestBundleID
        self.containerUUID = containerUUID
        self.diskDirectoryName = diskDirectoryName
        self.keychainGroup = keychainGroup
        self.stage = stage
        self.createdAt = createdAt
        self.stageDetail = stageDetail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        guestBundleID = try container.decode(String.self, forKey: .guestBundleID)
        containerUUID = try container.decode(String.self, forKey: .containerUUID)
        // 旧收据（无这两个键）按缺省处理，不丢整条收据。
        diskDirectoryName = try container.decodeIfPresent(String.self, forKey: .diskDirectoryName)
            ?? (guestBundleID + ".app")
        keychainGroup = try container.decodeIfPresent(Int.self, forKey: .keychainGroup) ?? -1
        stage = try container.decode(String.self, forKey: .stage)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        stageDetail = try container.decodeIfPresent(String.self, forKey: .stageDetail)
    }

    static func requested(guestBundleID: String, containerUUID: String,
                          diskDirectoryName: String? = nil, keychainGroup: Int = -1) -> SBLaunchReceipt {
        SBLaunchReceipt(
            requestID: UUID().uuidString,
            guestBundleID: guestBundleID,
            containerUUID: containerUUID,
            diskDirectoryName: diskDirectoryName ?? (guestBundleID + ".app"),
            keychainGroup: keychainGroup,
            stage: "restart-requested",
            createdAt: Date(),
            stageDetail: nil)
    }
}
