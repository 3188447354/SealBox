import SwiftUI
import Foundation

/// Which app is open on top of the home screen, if any.
enum VMApp: Hashable {
    case settings
    case source
    case plugins
    /// 已装应用详情页：payload 是 SBStore 里那条记录的 recordID（UUID 字符串），
    /// 不再是名字——平行安装的两条同名记录必须能区分开。
    case installed(String)
    case phone
    case safari
    case messages
    case music
}

/// Shared navigation state only. The installed-apps list used to live here
/// (standard UserDefaults, key `vm.installedApps`, name/version/fileName/
/// category only); since 0.2.0 step 8 the single source of truth is
/// SBStore.shared.installedApps (App Group UserDefaults, SBInstalledApp
/// records keyed by recordID UUID, ordered by desktopIconOrder).
/// The old `vm.installedApps` data is still read once by SBMigration from
/// standard UserDefaults directly — nothing here depends on it anymore.
final class VMState: ObservableObject {
    @Published var openApp: VMApp?
    @Published var homePage: Int = 0
}
