import Foundation

/// 启动诊断日志的 Swift 入口（实现在 SBDiagLog.c，纯 C，不依赖 Foundation）。
/// 写日志永不抛错、永不弹框：失败时静默丢弃，绝不能成为新的崩点。
enum SBDiagLog {
    /// 进程启动时最先调用：开本次启动的新日志文件，写第一行。
    static func beginRun() { SBDiagLogBeginRun() }

    /// 记一行（带时间戳），写完立即刷盘。
    static func log(_ step: String) {
        step.withCString { SBDiagLogLine($0) }
    }

    /// 正常启动完成时调用：写完成标记。
    static func markStartupComplete() { SBDiagLogMarkStartupComplete() }

    /// 是否有保留下来的崩溃日志（任一 -crashed 文件）。
    static var hasCrashedLog: Bool { SBDiagLogHasCrashedLog() != 0 }

    /// 最近一次启动日志全文：最新崩过的那份优先，其次最新一份。
    static func latestText() -> String? {
        guard let ptr = SBDiagLogLatestText() else { return nil }
        defer { free(ptr) }
        return String(cString: ptr)
    }

    /// 日志文件夹里的文件列表（最新在前）。
    static func fileList() -> [SBDiagLogFile] {
        guard let ptr = SBDiagLogFileList() else { return [] }
        defer { free(ptr) }
        let raw = String(cString: ptr)
        return raw.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count == 3, let bytes = Int(parts[2]) else { return nil }
            return SBDiagLogFile(name: String(parts[0]),
                                 crashed: parts[1] == "1",
                                 bytes: bytes)
        }
    }

    /// 读日志文件夹里指定文件全文（name 只认 basename）。
    static func readFile(_ name: String) -> String? {
        guard let ptr = name.withCString({ SBDiagLogReadNamedFile($0) }) else { return nil }
        defer { free(ptr) }
        return String(cString: ptr)
    }

    /// 本次启动的日志文件名（不含目录）。
    static func currentFileName() -> String? {
        guard let ptr = SBDiagLogCurrentFileName() else { return nil }
        defer { free(ptr) }
        return String(cString: ptr)
    }
}

/// 日志文件夹里的一份日志文件。
struct SBDiagLogFile: Identifiable, Hashable {
    let name: String       // 文件名，如 SBStartupLog-2026-11-21-010321-9021-crashed.txt
    let crashed: Bool      // 上次启动没完成就崩了
    let bytes: Int
    var id: String { name }

    /// 可读标题：2026-11-21 01:03:21 · pid 9021（旧日志显示“旧日志”）。
    var displayName: String {
        var stem = name
        if stem.hasPrefix("SBStartupLog-") { stem.removeFirst("SBStartupLog-".count) }
        if stem.hasSuffix(".txt") { stem.removeLast(".txt".count) }
        if stem.hasSuffix("-crashed") { stem.removeLast("-crashed".count) }
        let parts = stem.split(separator: "-")
        guard parts.count >= 4 else { return name }
        let date = parts[0...2].joined(separator: "-")
        let time = String(parts[3])
        guard time.count == 6 else { return name }
        let clock = "\(time.prefix(2)):\(time.dropFirst(2).prefix(2)):\(time.dropFirst(4))"
        let tail = parts.dropFirst(4).joined(separator: "-")
        if tail.isEmpty {
            return "\(date) \(clock)"
        } else if Int(tail) != nil {
            return "\(date) \(clock) · pid \(tail)"
        } else {
            return "\(date) \(clock) · 旧日志"
        }
    }

    /// 可读大小：12 KB / 800 B。
    var displaySize: String {
        if bytes >= 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes) B"
    }
}
