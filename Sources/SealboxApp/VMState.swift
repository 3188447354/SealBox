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
    /// 0.2.37：桌面页码持久化（MJ 22:35：每次进 SealBox 都默认第一页，改成有记忆的）。
    /// 桌面只有 0/1 两页，越界值钳到 0；每次翻页/点圆点都写盘，进 SealBox 与从客回
    /// 桌面都恢复上次所在页。UserDefaults 标准域（桌面状态只属宿主，不进 App Group）。
    @Published var homePage: Int {
        didSet {
            let clamped = (homePage == 1) ? 1 : 0
            if clamped != homePage {
                homePage = clamped
                return
            }
            UserDefaults.standard.set(homePage, forKey: "vm.homePage")
        }
    }

    init() {
        let stored = UserDefaults.standard.integer(forKey: "vm.homePage")
        homePage = (stored == 1) ? 1 : 0
    }
}
