import SwiftUI

/// Which app is open on top of the home screen, if any.
enum VMApp: Hashable {
    case settings
    case source
    case plugins
    case installed(String) // app name from the software source
}

/// An app downloaded from the software source, saved under Documents/IPAs.
struct InstalledApp: Codable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let version: String
    let fileName: String
    let category: String
}

/// Shared navigation + installed-apps state. All on/off toggles live as
/// @AppStorage in the views that use them (same key = same value everywhere);
/// this object only holds things that must notify observers.
final class VMState: ObservableObject {
    @Published var openApp: VMApp?
    @Published var homePage: Int = 0
    @Published var installed: [InstalledApp] = []

    private let installedKey = "vm.installedApps"

    init() {
        if let data = UserDefaults.standard.data(forKey: installedKey),
           let apps = try? JSONDecoder().decode([InstalledApp].self, from: data) {
            installed = apps
        }
    }

    func isInstalled(_ name: String) -> Bool {
        installed.contains { $0.name == name }
    }

    func addInstalled(_ app: InstalledApp) {
        guard !isInstalled(app.name) else { return }
        installed.append(app)
        if let data = try? JSONEncoder().encode(installed) {
            UserDefaults.standard.set(data, forKey: installedKey)
        }
    }
}
