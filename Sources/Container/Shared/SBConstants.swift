import Foundation

/// Sealbox 全局常量（新产品，不含 LiveContainer 内容）。
enum SBConstants {
    /// App Group suite 名：Release 下为 group.com.mjorb.sealbox，与 entitlements 的
    /// $(APP_GROUP_SEALBOX) 一致；Debug 带 team 后缀时同样由 bundleIdentifier 推出。
    static var appGroupSuiteName: String {
        "group." + (Bundle.main.bundleIdentifier ?? "com.mjorb.sealbox")
    }

    /// 宿主 Documents 下的目录名。
    static let guestAppsDirectoryName = "Applications"
    static let guestDataDirectoryName = "Data/Application"
    static let tweaksDirectoryName = "Tweaks"

    /// 客 App 落位目录（Documents/Applications）、数据容器父目录、Hook 库目录。
    /// 安装器按契约名直接用这三个 URL。
    static var guestAppsDir: URL {
        documentsURL.appendingPathComponent(guestAppsDirectoryName)
    }

    static var guestDataDir: URL {
        documentsURL.appendingPathComponent(guestDataDirectoryName)
    }

    static var tweaksDir: URL {
        documentsURL.appendingPathComponent(tweaksDirectoryName)
    }

    /// 客端 Hook 库文件名（宿主包内 Frameworks/ 下，同时复制到 Documents/Tweaks/）。
    static let guestHooksDylibName = "SBGuestHooks.dylib"

    /// 证书文件（App Group 容器内）。
    static let certificateFileName = "Certificate.p12"

    /// 重启请求看门狗：发出请求后本进程若在此时限内仍活着，即判定请求被系统丢弃。
    static let restartDeadlineSeconds: TimeInterval = 5.0

    /// Mach-O 补丁版本号；低于它的客 App 启动前重打补丁。
    /// 0.2.5：LC_ID_DYLIB、dylib 去重、entitlements、段数 mismatch 改为标记。
    /// 0.2.17：打补丁器与重签流程改用 LiveContainer 原样方法（LC 的
    /// LCPatchExecSlice + 宿主 Bundle ID 全包重签 + 内核验签门），已装的
    /// 旧包下次点图标/重启自动重打补丁+重签。
    static let patchRevision = 3

    /// 钥匙串半隔离组数（与 entitlements.xml 的 128 组一致）。
    static let keychainGroupCount = 128
    static let keychainGroupPrefix = "com.mjorb.sealbox.shared"

    static func keychainGroupName(for index: Int) -> String {
        index <= 0 ? keychainGroupPrefix : "\(keychainGroupPrefix).\(index)"
    }

    /// 客 App bundle 在磁盘上的位置。
    static func guestAppDirectoryURL(bundleID: String, documentsURL: URL) -> URL {
        documentsURL
            .appendingPathComponent(guestAppsDirectoryName)
            .appendingPathComponent(bundleID + ".app")
    }

    /// 客 App 数据容器位置。
    static func guestDataContainerURL(containerUUID: String, documentsURL: URL) -> URL {
        documentsURL
            .appendingPathComponent(guestDataDirectoryName)
            .appendingPathComponent(containerUUID)
    }

    /// 客端 Hook 库在 Documents/Tweaks/ 下的位置（补丁注入的 LC_LOAD_DYLIB 目标）。
    static func tweaksHookDylibURL(documentsURL: URL) -> URL {
        documentsURL
            .appendingPathComponent(tweaksDirectoryName)
            .appendingPathComponent(guestHooksDylibName)
    }

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var appGroupContainerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupSuiteName)
    }
}
