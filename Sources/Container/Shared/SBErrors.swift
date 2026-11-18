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
    /// 0.2.8：客应用签名 Team 与宿主 Team 不一致，dyld 的 Library Validation
    ///（F_CHECK_LV）会拒绝加载。这不是签名损坏（签名本身可能完全有效），
    ///是部署配对问题：宿主须与客应用用同一证书签名。重签客应用修不好
    ///（重签换不了宿主的 Team），不要给“删除后重新导入”这种误导建议。
    /// hostTeam 为 nil 表示宿主没有 Team（CI 自签原样安装）。
    case teamMismatch(guestTeam: String, hostTeam: String?)
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
        case .teamMismatch: return "签名"
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
        case .teamMismatch(let guestTeam, let hostTeam):
            return "客应用签名 Team（\(guestTeam)）与宿主 Team（\(hostTeam ?? "无")）不一致，系统会拒绝加载客应用"
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

    /// 稳定数字码（0.2.10 报错日志用）：每条报错记录都带这个码，日志里
    /// 一眼定位是哪一类失败。与 ObjC 的 SBGuestLoaderErrorCode
    ///（1001–1010）不重叠；新增 case 时往后加，不要改已有值。
    var code: Int {
        switch self {
        case .cancelled: return 2001
        case .notAnIPA: return 2002
        case .unzipFailed: return 2003
        case .noAppBundle: return 2004
        case .infoPlistUnreadable: return 2005
        case .noBundleID: return 2006
        case .encryptedIPA: return 2007
        case .patchFailed: return 2008
        case .signFailed: return 2009
        case .teamMismatch: return 2010
        case .missingCertificate: return 2011
        case .certificateDeleted: return 2012
        case .certificateExpired: return 2013
        case .certificateInvalid: return 2014
        case .restartRequestFailed: return 2015
        case .needsJIT: return 2016
        case .guestLoadFailed: return 2017
        case .selfTestFailed: return 2018
        case .installInProgress: return 2019
        case .generic: return 2020
        }
    }

    /// 恢复建议：显示在报错弹窗的次要文案或按钮旁。    var recoverySuggestion: String? {
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
        case .teamMismatch:
            return "宿主应用需要用同一证书签名才能打开客应用"
        default:
            return nil
        }
    }
}
