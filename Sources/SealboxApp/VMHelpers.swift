import SwiftUI
import Foundation
import UIKit

// Shared helpers for the VM shell (0.1.7).
// Rule (MJ 2026-11-18, highest priority): NO fake data. Everything here
// returns real values from the system / disk / user input, or a VM-local
// setting value. Nothing is invented: no fake battery, traffic, capacity,
// serial number, device name, contact, song, message or call record.

/// The four wallpaper options. The names are the VM's own setting labels
/// (not claims about the real world); the colors are what the home screen
/// actually draws. Shared by the home screen and the wallpaper page so
/// the two can never drift apart.
enum VMWallpapers {
    static let options: [(name: String, colors: [Color])] = [
        ("蓝紫粉渐变", [.blue, .purple, .pink]),
        ("深海蓝", [.blue, .teal, .black]),
        ("落日橙", [.orange, .pink, .purple]),
        ("森林绿", [.green, .teal, .mint]),
    ]

    static func colors(for index: Int) -> [Color] {
        let safe = options.indices.contains(index) ? index : 0
        return options[safe].colors
    }
}

/// 0.2.37：用户自选图片（墙纸与头像共用）：只存用户自己挑的真实图片，不内置
/// 任何占位图。文件落在宿主 Documents 下（墙纸 Wallpaper/、头像 Avatar/），
/// AppStorage 的 customVersion 计数作变更信号（HomeScreen 与设置页都监听它，
/// 存/删时 +1，图片本身不走 UserDefaults）。
enum VMUserImage {
    /// 下采样后存 JPEG：长边不超过 maxDimension，质量 0.85——墙纸 2000、头像 512。
    /// 返回 JPEG 数据；原图已是 JPEG 且够小也不直存原文件，统一经此路（尺寸可控）。
    static func jpegData(_ image: UIImage, maxDimension: CGFloat, quality: CGFloat = 0.85) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    static func directory(named name: String) throws -> URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dir = docs.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// 0.2.37：自定义墙纸（MJ 22:39）：用户从相册/文件挑一张图，存
/// Documents/Wallpaper/custom-wallpaper.jpg；没选时用渐变墙纸。
enum VMCustomWallpaper {
    static let fileName = "custom-wallpaper.jpg"
    static var fileURL: URL? { try? VMUserImage.directory(named: "Wallpaper").appendingPathComponent(fileName) }

    /// 当前是否有用户自选墙纸（文件在即有）。
    static var hasCustom: Bool {
        guard let url = fileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func loadImage() -> UIImage? {
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// 存入用户挑的图片（下采样长边 ≤2000 后写盘）；成功返回 true。
    @discardableResult
    static func save(_ image: UIImage) -> Bool {
        guard let url = fileURL,
              let data = VMUserImage.jpegData(image, maxDimension: 2000) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 恢复默认墙纸：删掉自选图文件（没有也不报错）。
    static func remove() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// 0.2.37：自定义头像（MJ 22:40）：与墙纸同一套存法，文件在
/// Documents/Avatar/custom-avatar.jpg，下采样长边 ≤512。
enum VMUserAvatar {
    static let fileName = "custom-avatar.jpg"
    static var fileURL: URL? { try? VMUserImage.directory(named: "Avatar").appendingPathComponent(fileName) }

    static var hasCustom: Bool {
        guard let url = fileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func loadImage() -> UIImage? {
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    @discardableResult
    static func save(_ image: UIImage) -> Bool {
        guard let url = fileURL,
              let data = VMUserImage.jpegData(image, maxDimension: 512) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func remove() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Real disk measurements, from FileManager — never invented numbers.
enum VMFiles {
    /// Documents/IPAs, creating it on first use.
    static func ipasDirectory() throws -> URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dir = docs.appendingPathComponent("IPAs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Human-readable size of one file in Documents/IPAs, or nil if absent.
    static func ipaFileSizeString(fileName: String) -> String? {
        guard let dir = try? ipasDirectory() else { return nil }
        let url = dir.appendingPathComponent(fileName)
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 else { return nil }
        return formatBytes(size)
    }

    /// Human-readable total size of a directory tree (installed .app bundle),
    /// or nil when the directory does not exist.
    static func directorySizeString(url: URL) -> String? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var total: Int64 = 0
        var found = false
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory != true else { continue }
            total += Int64(values.fileSize ?? 0)
            found = true
        }
        return found ? formatBytes(total) : nil
    }

    /// Total size of everything in Documents/IPAs (real disk measurement).
    static func ipasDirectorySizeString() -> String {
        guard let dir = try? ipasDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return formatBytes(0) }
        var total: Int64 = 0
        for url in urls {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return formatBytes(total)
    }

    /// Real volume total / available space, read from the file system.
    static func diskSpace() -> (total: String, available: String) {
        let values = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let total = (values?[.systemSize] as? Int64) ?? 0
        let free = (values?[.systemFreeSize] as? Int64) ?? 0
        return (formatBytes(total), formatBytes(free))
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }
}

/// Real device values, from the system itself.
enum VMDevice {
    /// Real hardware identifier, e.g. "iPhone17,2" (from uname — the system).
    static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                String(validatingUTF8: ptr) ?? "未知"
            }
        }
        return machine
    }

    /// Real iOS version string, e.g. "27.2.1".
    static var systemVersion: String { UIDevice.current.systemVersion }

    /// Real per-vendor device identifier.
    static var vendorIdentifier: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "未知"
    }

    /// This app's own version, e.g. "0.1.7（8）".
    static var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = info?["CFBundleVersion"] as? String ?? "未知"
        return "\(version)（\(build)）"
    }
}

/// Passwords the VM generates for its own settings (hotspot password).
/// These are VM-local setting values, not claims about the real world.
enum VMPasswords {
    static func randomHotspotPassword() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
}

/// Time formatting built from date components (no shared DateFormatter —
/// Swift 6 concurrency-safe, same pattern as FancyStatusBar).
enum VMTime {
    /// mm:ss for an elapsed interval.
    static func mmss(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// "11月18日 07:10" from the real clock.
    static func dateTimeString(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
        return String(format: "%d月%d日 %02d:%02d", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// "2026年11月18日" from the real clock.
    static func dateString(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%d年%d月%d日", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "07:10:25" from the real clock.
    static func timeString(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
