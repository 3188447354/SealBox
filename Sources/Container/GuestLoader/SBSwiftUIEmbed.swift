import SwiftUI
import UIKit

/// SwiftUI 客的进程内嵌 App 场景（0.2.28）。
///
/// 由 ObjC 替身 SBHookedAppMain 调（@_cdecl 导出，C 调用约定）：
/// 拿客 App 类型元数据建实例，取 body 的 WindowGroup 内容视图，包进
/// UIHostingController，交给会话管理器激活（与 UIKit 客同一会话管理器、
/// 同一窗口/scene 处理，侧滑回宿主与多客后台保留同样生效）。
///
/// 本机无 Swift 编译器，Mirror/闭包强转/AnyView 的运行时行为只能靠 CI 编译
/// ＋设备日志验证——每步都记诊断日志（App 类型名、body 类型名、WindowGroup
/// 子项标签/类型、闭包是否找到、调用结果类型），失败只返回 false，不抛异常、
/// 不调原 App.main（替身收到 false 即置激活错误，bootstrap 按失败处理）。
@_cdecl("SBSwiftUIEmbedApp")
public func SBSwiftUIEmbedApp(_ metadata: UnsafeRawPointer,
                              _ context: SBGuestMainHookContext) -> Bool {
    // —— 1. 元数据 → App 类型 ————————————————————————————
    // 元数据指针本身就是类型的身份：bit cast 成 Any.Type。
    let anyType = unsafeBitCast(metadata, to: Any.Type.self)
    guard let appType = anyType as? any App.Type else {
        SBDiagLog.log("SwiftUI 嵌客：元数据强转 any App.Type 失败（类型 \(anyType)）")
        return false
    }
    SBDiagLog.log("SwiftUI 嵌客：App 类型 \(appType)（元数据 \(metadata)）")

    // —— 2. 建 App 实例 ————————————————————————————————
    let app = appType.init()

    // —— 3. @UIApplicationDelegateAdaptor（有则取 delegate，无则跳过） ————
    var appDelegate: UIApplicationDelegate?
    for child in Mirror(reflecting: app).children {
        let typeName = String(describing: type(of: child.value))
        guard typeName.contains("UIApplicationDelegateAdaptor") else { continue }
        SBDiagLog.log("SwiftUI 嵌客：找到 @UIApplicationDelegateAdaptor 属性（\(typeName)）")
        // adaptor 是属性包装器，delegate 在它里面；Mirror 扫一层找能转成
        // UIApplicationDelegate 的子项。
        for sub in Mirror(reflecting: child.value).children {
            if let delegate = sub.value as? UIApplicationDelegate {
                appDelegate = delegate
                break
            }
        }
        if let delegate = appDelegate {
            SBDiagLog.log("SwiftUI 嵌客：adaptor delegate 已找到（\(String(describing: type(of: delegate)))）")
        } else {
            SBDiagLog.log("SwiftUI 嵌客：adaptor delegate 未找到")
        }
        break
    }

    // —— 4. body → WindowGroup ———————————————————————————
    let body = app.body
    let bodyTypeName = String(describing: type(of: body))
    SBDiagLog.log("SwiftUI 嵌客：App body 类型 \(bodyTypeName)")
    var windowGroup: Any?
    if bodyTypeName.contains("WindowGroup") {
        windowGroup = body
    } else {
        // 多场景（TupleScene/Group）时 Mirror 扫子项找 WindowGroup。
        for child in Mirror(reflecting: body).children {
            if String(describing: type(of: child.value)).contains("WindowGroup") {
                windowGroup = child.value
                break
            }
        }
    }
    guard let group = windowGroup else {
        SBDiagLog.log("SwiftUI 嵌客：body 里找不到 WindowGroup（body 类型 \(bodyTypeName)）")
        return false
    }

    // —— 5. WindowGroup 内容闭包 → 根视图 ————————————————————
    // WindowGroup 按窗口建内容，存的是 @escaping () -> Content 闭包，
    // 不是单个 Content 值。Mirror 子项里找函数类型子项，强转 () -> Any
    // 后调用（Swift 函数类型返回协变，() -> ContentView 可转为 () -> Any）。
    var rootView: (any View)?
    for child in Mirror(reflecting: group).children {
        let label = child.label ?? "(无标签)"
        let childTypeName = String(describing: type(of: child.value))
        SBDiagLog.log("SwiftUI 嵌客：WindowGroup 子项 \(label)：\(childTypeName)")
        guard let contentFn = child.value as? () -> Any else { continue }
        guard let view = contentFn() as? any View else {
            SBDiagLog.log("SwiftUI 嵌客：内容闭包调用结果不是 View（\(label)）")
            continue
        }
        rootView = view
        SBDiagLog.log("SwiftUI 嵌客：根视图类型 \(String(describing: type(of: view)))（子项 \(label)）")
        break
    }
    guard let view = rootView else {
        SBDiagLog.log("SwiftUI 嵌客：WindowGroup 里找不到内容闭包或调用后不是 View")
        return false
    }

    // —— 6. 包进 UIHostingController，交给会话管理器激活 ————————————
    let hosting = UIHostingController(rootView: AnyView(view))
    do {
        try SBGuestSessionManager.shared().activateSwiftUIGuest(
            with: context,
            hostingController: hosting,
            appInstance: app,
            appDelegate: appDelegate)
        SBDiagLog.log("SwiftUI 嵌客：会话激活成功，\(context.bundleID) 已在前台")
        return true
    } catch {
        SBDiagLog.log("SwiftUI 嵌客：会话激活失败（\(error.localizedDescription)）")
        return false
    }
}

/// Swift 覆盖层 UIApplicationMain 的替身（0.2.30）。
///
/// Flutter/Swift-main 客的 main 调的不是 C UIApplicationMain，而是 UIKit 的
/// Swift 覆盖层函数 `UIKit.UIApplicationMain(_:_:_:_:)`（mangled
/// _$s5UIKit17UIApplicationMainys5Int32VAD_SpySpys4Int8VGGSgSSSgAJtF，
/// 原型 0230：OmoFun Runner 链式 import 序号 41，__DATA_CONST 槽 0x8150，
/// 指针格式 6）。C 符号重绑够不着它，须按 Swift ABI 接：参数与覆盖层签名逐字
/// 相同（Int32，argv，String?，String?），@_cdecl 导出，ObjC 侧只取地址写进
/// 客 __got 槽。体内 String? 直传 ObjC 替身 SBHookedUIApplicationMain
///（调用边界桥接成 NSString?，同一判别器：新鲜进程第一遍转发、进程内第二遍
/// 拦截激活）；覆盖层本身只是 String?→NSString? 的薄转发，第一遍转发直接调
/// C UIApplicationMain 与之一致。
/// ABI 说明：此签名的 Swift 调用约定与 C 一致（Int32→w0，指针→x1，
/// 16 字节 String?→x2:x3 与 x4:x5，返回 Int32→w0），@_cdecl 函数可直接接。
@_cdecl("SBHookedSwiftUIApplicationMain")
public func SBHookedSwiftUIApplicationMain(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ principalClassName: String?,
    _ delegateClassName: String?
) -> Int32 {
    SBDiagLog.log("拦截 Swift UIApplicationMain：principal=\(principalClassName ?? "(nil)") delegate=\(delegateClassName ?? "(nil)")（走 ObjC 替身判别：第一遍转发／第二遍拦截）")
    let result = SBHookedUIApplicationMain(argc, argv, principalClassName, delegateClassName)
    // 0.2.32：替身返回前记一行——0.2.31 phoenix 三回都死在“会话激活成功”
    // 之后、0.4 秒补查之前；有此行而无 bootstrap 的“客 main 已返回”，
    // 死在客 main 收尾；无此行，死在替身返回本身（首遍转发时真实
    // UIApplicationMain 不返回，此行只会在拦截路出现）。
    SBDiagLog.log("拦截 Swift UIApplicationMain：替身返回 \(result)（客 main 将返回）")
    return result
}
