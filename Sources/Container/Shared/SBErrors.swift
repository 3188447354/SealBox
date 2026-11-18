import Foundation

/// Sealbox 错误：每个错误都带中文阶段名（卡在哪一步）与恢复建议。
/// 阶段名会直接显示给用户，超时与失败一律按阶段报错，不许无限等待、不许静默。
enum SBError: LocalizedError {
    case cancelled
    case notAnIPA
    case unzipFailed(underlying: String)
    case noAppBundle
    case infoPlistUnreadable
    case noBundleID
    case encryptedIPA
    case patchFailed(reason: String)
    case signFailed(reason: String)
    case missingCertificate
    case certificateDeleted
    case certificateExpired
    case certificateInvalid(reason: String)
    case restartRequestFailed
    case needsJIT
    case guestLoadFailed(reason: String)
    case selfTestFailed(stage: String, reason: String)
    case installInProgress
    case generic(stage: String, message: String)

    var stage: String {
        switch self {
        case .cancelled: return "已取消"
        case .notAnIPA: return "选择文件"
        case .unzipFailed: return "解压"
        case .noAppBundle: return "解压"
        case .infoPlistUnreadable: return "读取信息"
        case .noBundleID: return "读取信息"
        case .encryptedIPA: return "安装"
        case .patchFailed: return "打补丁"
        case .signFailed: return "签名"
        case .missingCertificate: return "证书检查"
        case .certificateDeleted: return "证书检查"
        case .certificateExpired: return "证书检查"
        case .certificateInvalid: return "证书检查"
        case .restartRequestFailed: return "重启请求"
        case .needsJIT: return "加载客 App"
        case .guestLoadFailed: return "加载客 App"
        case .selfTestFailed(let stage, _): return stage
        case .installInProgress: return "安装"
        case .generic(let stage, _): return stage
        }
    }

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "已取消"
        case .notAnIPA:
            return "所选文件不是 IPA"
        case .unzipFailed(let underlying):
            return "解压失败：\(underlying)"
        case .noAppBundle:
            return "IPA 里没有找到 .app"
        case .infoPlistUnreadable:
            return "读不到应用信息（Info.plist）"
        case .noBundleID:
            return "读不到应用的 Bundle ID"
        case .encryptedIPA:
            return "该 IPA 是 App Store 加密包，无法安装，请提供已解密的 IPA"
        case .patchFailed(let reason):
            return "打补丁失败：\(reason)"
        case .signFailed(let reason):
            return "签名失败：\(reason)"
        case .missingCertificate:
            return "未导入证书，请先导入证书"
        case .certificateDeleted:
            return "证书已被删除，请重新导入证书"
        case .certificateExpired:
            return "证书已过期，请重新导入"
        case .certificateInvalid(let reason):
            return "证书无效：\(reason)"
        case .restartRequestFailed:
            return "系统没有重启应用，请重试"
        case .needsJIT:
            return "该应用需要 JIT 才能运行"
        case .guestLoadFailed(let reason):
            return "客 App 加载失败：\(reason)"
        case .selfTestFailed(_, let reason):
            return "自测失败：\(reason)"
        case .installInProgress:
            return "正在安装，请稍候"
        case .generic(_, let message):
            return message
        }
    }

    /// 恢复建议：显示在报错弹窗的次要文案或按钮旁。
    var recoverySuggestion: String? {
        switch self {
        case .missingCertificate, .certificateDeleted, .certificateExpired:
            return "去导入证书"
        case .needsJIT:
            return "请用 Seal 开启 JIT 后重试，或换用 64 位版本"
        case .restartRequestFailed, .guestLoadFailed:
            return "重试"
        case .encryptedIPA:
            return "请提供已解密的 IPA"
        case .signFailed:
            return "应用已按未签名状态安装，可尝试用 JIT 启动"
        default:
            return nil
        }
    }
}
