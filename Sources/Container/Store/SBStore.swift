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
        /// 种子应用 Via 已装过（0.2.1）：置位后不再自动种；用户删了也不补。
        static let seedViaInstalled = "SBSeedViaInstalled"
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

    /// 0.2.2 闪退根因修：`installedApps` 是 @Published、被桌面（HomeScreenView
    /// 的 @ObservedObject）观察，但安装 / 迁移 / 删除管线都在后台线程跑
    /// （种子安装 Task、SBMigration 的 Task.detached、ZSign 回调所在的全局队列）。
    /// 0.2.1 之前这些后台线程直接写 `installedApps`，SwiftUI 禁止后台线程发布
    /// 变更，设备上间歇闪退——0.2.1 首启 Via 种子安装必经此路，所以一开就崩。
    /// 以下所有读写 `installedApps` 的方法一律经 `onMain` 回主线程；已在主线程
    /// 时直接跑，不发同步派发。主线程从不阻塞等这些后台任务（全是 Task / await），
    /// 所以 main.sync 不会死锁；嵌套调用时内层见已在主线程、直接跑。
    /// UserDefaults 直读直写的字段（顺序、收据、旗标）本身线程安全，不走这里。
    private func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    @Published private(set) var installedApps: [SBInstalledApp] = []

    func loadInstalledApps() -> [SBInstalledApp] {
        onMain {
            guard let data = defaults.data(forKey: Key.installedApps) else {
                installedApps = []
                return []
            }
            let apps = (try? Self.jsonDecoder.decode([SBInstalledApp].self, from: data)) ?? []
            installedApps = apps
            return apps
        }
    }

    func saveInstalledApps(_ apps: [SBInstalledApp]) {
        onMain {
            installedApps = apps
            if let data = try? Self.jsonEncoder.encode(apps) {
                defaults.set(data, forKey: Key.installedApps)
            }
        }
    }

    func app(with bundleID: String) -> SBInstalledApp? {
        onMain { installedApps.first { $0.bundleID == bundleID } }
    }

    /// 同 Bundle ID 的全部记录（平行安装时多条共存）。
    func apps(with bundleID: String) -> [SBInstalledApp] {
        onMain { installedApps.filter { $0.bundleID == bundleID } }
    }

    /// 按 recordID 匹配：平行安装的两条同 Bundle ID 记录必须共存，
    /// 原按 Bundle ID 替换会把平行安装的另一条吃掉（0.1.0 缺陷）。
    func upsertApp(_ app: SBInstalledApp) {
        onMain {
            var apps = installedApps
            if let index = apps.firstIndex(where: { $0.recordID == app.recordID }) {
                apps[index] = app
            } else {
                apps.append(app)
            }
            saveInstalledApps(apps)
        }
    }

    /// 只删记录，不删文件（文件删除由 Installer/Uninstaller 做）。
    /// 按 recordID 删，并同步清理桌面顺序与 Dock 顺序里该 recordID。
    func removeAppRecord(recordID: UUID) {
        onMain {
            let recordIDString = recordID.uuidString
            saveInstalledApps(installedApps.filter { $0.recordID != recordID })
            var order = desktopIconOrder
            order.removeAll { $0 == recordIDString }
            desktopIconOrder = order
            var dock = desktopDockOrder
            dock.removeAll { $0 == recordIDString }
            desktopDockOrder = dock
        }
    }

    /// 0.2.14：失败标记按 bundleID + diskDirectoryName 写到对应的那条
    /// 记录（平行安装的两条同名记录必须分开记；只按 bundleID 找首条时，
    /// 标记可能写到另一条平行安装的记录上，门读的那条永远读不到——
    /// 0.2.13 的 hdsh 触发器没生效的候选根因之一）。diskDirectoryName
    /// 为空时退到只按 bundleID 找首条（旧收据没有目录名时的兜底）。
    func recordLaunchResult(bundleID: String, diskDirectoryName: String? = nil,
                           success: Bool, message: String) {
        onMain {
            let app: SBInstalledApp?
            if let dir = diskDirectoryName, !dir.isEmpty {
                app = installedApps.first {
                    $0.bundleID == bundleID && $0.diskDirectoryName == dir
                } ?? self.app(with: bundleID)
            } else {
                app = self.app(with: bundleID)
            }
            guard var app = app else { return }
            app.lastLaunchResult = SBLaunchResult(
                success: success, date: Date(), message: message)
            upsertApp(app)
        }
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

    // MARK: - 种子应用（0.2.1：Via）

    /// Via 种子已装过：置位后首次启动不再自动种；用户删了也不补。
    var seedViaInstalled: Bool {
        get { defaults.bool(forKey: Key.seedViaInstalled) }
        set { defaults.set(newValue, forKey: Key.seedViaInstalled) }
    }
}
