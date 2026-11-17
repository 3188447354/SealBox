import Foundation

/// 数据层：桌面顺序、Dock 成员、启动次数、已装应用与启动收据，
/// 全部存在 App Group UserDefaults 里，不另建数据库。
final class SBStore: ObservableObject {
    static let shared = SBStore()

    let defaults: UserDefaults

    private enum Key {
        static let installedApps = "SBInstalledApps"
        static let desktopIconOrder = "SBDesktopIconOrder"
        static let desktopDockOrder = "SBDesktopDockOrder"
        static let desktopDockManuallyEdited = "SBDesktopDockManuallyEdited"
        static let launchCounts = "SBLaunchCounts"
        static let selectedGuestBundleID = "SBSelectedGuestBundleID"
        static let selectedGuestContainer = "SBSelectedGuestContainer"
        static let launchReceipt = "SBLaunchReceipt"
        static let certificateImportedDate = "SBCertificateImportedDate"
        static let displayNameOverrides = "SBDisplayNameOverrides"
    }

    init(defaults: UserDefaults? = nil) {
        if let defaults = defaults {
            self.defaults = defaults
        } else if let suite = UserDefaults(suiteName: SBConstants.appGroupSuiteName) {
            self.defaults = suite
        } else {
            self.defaults = .standard
        }
    }

    // MARK: - JSON 编解码（日期一律用自 1970 的秒数）

    /// 收据由 ObjC 侧以自 1970 的秒数写 createdAt；Swift 默认的
    /// .deferredToDate 是自 2001 年的秒数，对不上，必须显式指定。
    static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    // MARK: - 已装应用

    @Published private(set) var installedApps: [SBInstalledApp] = []

    func loadInstalledApps() -> [SBInstalledApp] {
        guard let data = defaults.data(forKey: Key.installedApps) else {
            installedApps = []
            return []
        }
        let apps = (try? Self.jsonDecoder.decode([SBInstalledApp].self, from: data)) ?? []
        installedApps = apps
        return apps
    }

    func saveInstalledApps(_ apps: [SBInstalledApp]) {
        installedApps = apps
        if let data = try? Self.jsonEncoder.encode(apps) {
            defaults.set(data, forKey: Key.installedApps)
        }
    }

    func app(with bundleID: String) -> SBInstalledApp? {
        installedApps.first { $0.bundleID == bundleID }
    }

    /// 同 Bundle ID 的全部记录（平行安装时多条共存）。
    func apps(with bundleID: String) -> [SBInstalledApp] {
        installedApps.filter { $0.bundleID == bundleID }
    }

    /// 按 recordID 匹配：平行安装的两条同 Bundle ID 记录必须共存，
    /// 原按 Bundle ID 替换会把平行安装的另一条吃掉（0.1.0 缺陷）。
    func upsertApp(_ app: SBInstalledApp) {
        var apps = installedApps
        if let index = apps.firstIndex(where: { $0.recordID == app.recordID }) {
            apps[index] = app
        } else {
            apps.append(app)
        }
        saveInstalledApps(apps)
    }

    /// 只删记录，不删文件（文件删除由 Installer/Uninstaller 做）。
    /// 按 recordID 删，并同步清理桌面顺序与 Dock 顺序里该 recordID。
    func removeAppRecord(recordID: UUID) {
        let recordIDString = recordID.uuidString
        saveInstalledApps(installedApps.filter { $0.recordID != recordID })
        var order = desktopIconOrder
        order.removeAll { $0 == recordIDString }
        desktopIconOrder = order
        var dock = desktopDockOrder
        dock.removeAll { $0 == recordIDString }
        desktopDockOrder = dock
    }

    func recordLaunchResult(bundleID: String, success: Bool, message: String) {
        guard var app = app(with: bundleID) else { return }
        app.lastLaunchResult = SBLaunchResult(
            success: success, date: Date(), message: message)
        upsertApp(app)
    }

    func incrementLaunchCount(bundleID: String) {
        var counts = launchCounts
        counts[bundleID, default: 0] += 1
        launchCounts = counts
    }

    // MARK: - 桌面顺序 / Dock

    /// 桌面图标顺序：存 recordID 字符串（UUID 字符串），不再存 Bundle ID——
    /// 平行安装的两条同名记录在顺序里是两个不同条目。
    var desktopIconOrder: [String] {
        get { defaults.stringArray(forKey: Key.desktopIconOrder) ?? [] }
        set { defaults.set(newValue, forKey: Key.desktopIconOrder) }
    }

    /// Dock 顺序：同样存 recordID 字符串（见 desktopIconOrder）。
    var desktopDockOrder: [String] {
        get { defaults.stringArray(forKey: Key.desktopDockOrder) ?? [] }
        set { defaults.set(newValue, forKey: Key.desktopDockOrder) }
    }

    var desktopDockManuallyEdited: Bool {
        get { defaults.bool(forKey: Key.desktopDockManuallyEdited) }
        set { defaults.set(newValue, forKey: Key.desktopDockManuallyEdited) }
    }

    var launchCounts: [String: Int] {
        get { (defaults.dictionary(forKey: Key.launchCounts) as? [String: Int]) ?? [:] }
        set { defaults.set(newValue, forKey: Key.launchCounts) }
    }

    var displayNameOverrides: [String: String] {
        get { (defaults.dictionary(forKey: Key.displayNameOverrides) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Key.displayNameOverrides) }
    }

    func displayName(for app: SBInstalledApp) -> String {
        displayNameOverrides[app.bundleID] ?? app.displayName
    }

    // MARK: - 选中客 App / 启动收据

    var selectedGuestBundleID: String? {
        get { defaults.string(forKey: Key.selectedGuestBundleID) }
        set { defaults.set(newValue, forKey: Key.selectedGuestBundleID) }
    }

    var selectedGuestContainer: String? {
        get { defaults.string(forKey: Key.selectedGuestContainer) }
        set { defaults.set(newValue, forKey: Key.selectedGuestContainer) }
    }

    var launchReceipt: SBLaunchReceipt? {
        get {
            guard let data = defaults.data(forKey: Key.launchReceipt) else { return nil }
            return try? Self.jsonDecoder.decode(SBLaunchReceipt.self, from: data)
        }
        set {
            if let receipt = newValue,
               let data = try? Self.jsonEncoder.encode(receipt) {
                defaults.set(data, forKey: Key.launchReceipt)
            } else {
                defaults.removeObject(forKey: Key.launchReceipt)
            }
        }
    }

    func clearGuestSelection() {
        selectedGuestBundleID = nil
        selectedGuestContainer = nil
    }

    // MARK: - 证书

    /// 注意：证书密码不再存 UserDefaults 明文，改存系统钥匙串（SBKeychain，
    /// service `com.mjorb.sealbox.certificate-password`）；本类不再提供
    /// certificatePassword 属性。导入日期是非敏感信息，仍存这里。
    var certificateImportedDate: Date? {
        get { defaults.object(forKey: Key.certificateImportedDate) as? Date }
        set { defaults.set(newValue, forKey: Key.certificateImportedDate) }
    }
}
