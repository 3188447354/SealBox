import Foundation

/// 启动诊断日志的 Swift 入口（实现在 SBDiagLog.c，纯 C，不依赖 Foundation）。
/// 写日志永不抛错、永不弹框：失败时静默丢弃，绝不能成为新的崩点。
enum SBDiagLog {
    /// 进程启动时最先调用：轮转日志，写第一行。
    static func beginRun() { SBDiagLogBeginRun() }

    /// 记一行（带时间戳），写完立即刷盘。
    static func log(_ step: String) {
        step.withCString { SBDiagLogLine($0) }
    }

    /// 正常启动完成时调用：写完成标记。
    static func markStartupComplete() { SBDiagLogMarkStartupComplete() }

    /// 上次启动是否崩了（有保留下来的崩溃日志）。
    static var hasCrashedLog: Bool { SBDiagLogHasCrashedLog() != 0 }

    /// 最近一次启动日志全文：崩过的那份优先，其次上次的，再其次本次的。
    static func latestText() -> String? {
        guard let ptr = SBDiagLogLatestText() else { return nil }
        defer { free(ptr) }
        return String(cString: ptr)
    }
}
