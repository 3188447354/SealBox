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
///
/// 0.2.33：WindowGroup 内容递归钻取（RootContent，见第 5 步）＋ adaptor
/// delegate 递归查找/类名新建（见第 3 步）——Husk 真机四回：闭包找不到、
/// delegate 未找到。

/// 在一个值里递归找 UIApplicationDelegate：解 Optional、进盒子/结构体子项，
/// 深度 ≤3。找不到返回 nil（调用方决定后备方案，不抛异常）。
func findDelegate(in value: Any, depth: Int, path: String) -> UIApplicationDelegate? {
    if let delegate = value as? UIApplicationDelegate {
        return delegate
    }
    guard depth < 3 else { return nil }
    for child in Mirror(reflecting: value).children {
        let label = child.label ?? "(无标签)"
        if let found = findDelegate(in: child.value, depth: depth + 1, path: "\(path).\(label)") {
            return found
        }
    }
    return nil
}

/// 按 adaptor 泛型名建 delegate 实例：UIApplicationDelegateAdaptor<HuskAppDelegate>
/// ＋ App 类型 Husk.HuskApp → 先试读表找 "Husk.HuskAppDelegate"，
/// 再试 "HuskAppDelegate"。建不出返回 nil（调用方不挡窗口）。
/// 0.2.42：取类走 Mach-O 读表（SBGuestMachOClassNamedInGuest），不走
/// NSClassFromString——点开流程里运行时取类已全换成读表（见
/// SBGuestSessionManager.m 的 SBGuestClassNamedInGuest）；读表失败只干净
/// 失败、不回落运行时。读表本身是纯内存读，class-resolve 2s 阈值绰绰有余。
func buildDelegateFromAdaptorTypeName(_ adaptorTypeName: String, appType: Any.Type,
                                      guestExecPath: String, guestAppPath: String) -> UIApplicationDelegate? {
    guard let lt = adaptorTypeName.firstIndex(of: "<"),
          let gt = adaptorTypeName.firstIndex(of: ">"), lt < gt else { return nil }
    let delegateName = String(adaptorTypeName[adaptorTypeName.index(after: lt)..<gt])
    guard !delegateName.isEmpty else { return nil }
    let moduleName = String(reflecting: appType).split(separator: ".").first.map(String.init) ?? ""
    var candidates = [delegateName]
    if !moduleName.isEmpty {
        candidates.insert("\(moduleName).\(delegateName)", at: 0)
    }
    SBDiagLogWatchdogStepBegin("class-resolve", 2.0)
    defer { SBDiagLogWatchdogStepEnd("class-resolve") }
    for name in candidates {
        var reason: UnsafePointer<CChar>? = nil
        let ptr = name.withCString { cName in
            guestExecPath.withCString { cExec in
                guestAppPath.withCString { cApp in
                    SBGuestMachOClassNamedInGuest(cName, cExec, cApp, &reason)
                }
            }
        }
        guard let ptr else {
            let why = reason.map { String(cString: $0) } ?? "查无此类"
            SBDiagLog.log("SwiftUI 嵌客：adaptor delegate 读表未找到 \(name)（\(why)）")
            continue
        }
        // 读表给的类指针可能尚未实现化（bits 直指 ro）：首次发消息时
        // runtime 按正常路径实现化，与枚举给的已实现化类同效。
        guard let cls = unsafeBitCast(ptr, to: AnyClass.self) as? NSObject.Type else { continue }
        if let delegate = cls.init() as? UIApplicationDelegate {
            return delegate
        }
    }
    return nil
}

/// 在一个值里递归找根视图：本身是 View 即取；闭包经 C 层调后是 View 即取；
/// 否则 Mirror 钻子项；深度 ≤3。title 之类已在上层跳过。
/// 找不到返回 nil（调用方按失败处理，不抛异常）。
func findRootView(in value: Any, depth: Int, path: String) -> (any View)? {
    if let view = value as? any View {
        SBDiagLog.log("SwiftUI 嵌客：\(path) 本身是 View（\(String(describing: type(of: value)))），当根视图")
        return view
    }
    // 0.2.34：闭包值本身——Mirror 在闭包值上不显示子项（0.2.33 真机：
    // content.lazy 是 () -> SceneBridgeReader<...>，下一行却是“无子项，
    // 不是 View/闭包”），且 `as? () -> Any` 对具体返回类型的闭包强转失败
    // （函数类型强转要求精确匹配，无协变）。故按类型串识别函数值（类型串含
    // "->"）并经 C 层（SBSwiftClosureCall）按 Swift ABI 调用；调后验结果是 View。
    // 闭包分支放在“无子项”守卫之前：闭包值本身就是目标，不是钻取的死角。
    let typeName = String(describing: type(of: value))
    if typeName.contains("->") {
        SBDiagLog.log("SwiftUI 嵌客：\(path) 是闭包（\(typeName)），经 C 层调用")
        var result: Any = 0
        var errBuf = [CChar](repeating: 0, count: 256)
        let ok = withUnsafePointer(to: value) { ptr in
            SBCallSwiftClosure(UnsafeRawPointer(ptr), &result, &errBuf, errBuf.count)
        }
        if ok {
            if let view = result as? any View {
                SBDiagLog.log("SwiftUI 嵌客：闭包调用得 View（\(path)，结果 \(String(describing: type(of: result)))）")
                return view
            }
            SBDiagLog.log("SwiftUI 嵌客：闭包调用结果不是 View（\(path)，结果 \(String(describing: type(of: result)))）")
            return nil
        }
        SBDiagLog.log("SwiftUI 嵌客：闭包调用被拒（\(path)：\(String(cString: errBuf))）")
        return nil
    }
    guard depth < 3 else {
        SBDiagLog.log("SwiftUI 嵌客：\(path) 钻取到深度上限，停")
        return nil
    }
    let mirror = Mirror(reflecting: value)
    guard !mirror.children.isEmpty else {
        SBDiagLog.log("SwiftUI 嵌客：\(path) 无子项，不是 View/闭包")
        return nil
    }
    for child in mirror.children {
        let label = child.label ?? "(无标签)"
        let childPath = "\(path).\(label)"
        let childTypeName = String(describing: type(of: child.value))
        SBDiagLog.log("SwiftUI 嵌客：钻取 \(childPath)：\(childTypeName)")
        if let view = findRootView(in: child.value, depth: depth + 1, path: childPath) {
            return view
        }
    }
    return nil
}

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
    // 0.2.33：0.2.32 真机 Husk 四回都是“adaptor delegate 未找到”——单层
    // Mirror 扫不到：delegate 可能包在 Optional 里、装在引用型盒子里、或根本
    // 还没创建（SwiftUI 在 runApp 时才建）。修法：递归钻取（解 Optional、进
    // 盒子，深度 ≤3）；找不到再按 adaptor 泛型名读表建一个（先
    // "模块.Delegate" 再 "Delegate"，0.2.42 由 NSClassFromString 换成
    // Mach-O 读表）。仍找不到也不挡窗口：delegate 只影响客 AppDelegate
    // 方法跑不跑，不影响开窗。
    var appDelegate: UIApplicationDelegate?
    for child in Mirror(reflecting: app).children {
        let typeName = String(describing: type(of: child.value))
        guard typeName.contains("UIApplicationDelegateAdaptor") else { continue }
        SBDiagLog.log("SwiftUI 嵌客：找到 @UIApplicationDelegateAdaptor 属性（\(typeName)）")
        if let found = findDelegate(in: child.value, depth: 0, path: "adaptor") {
            appDelegate = found
            SBDiagLog.log("SwiftUI 嵌客：adaptor delegate 已找到（\(String(describing: type(of: found)))）")
        } else if let built = buildDelegateFromAdaptorTypeName(typeName, appType: appType,
                                                               guestExecPath: context.guestExecPath,
                                                               guestAppPath: context.guestAppPath) {
            appDelegate = built
            SBDiagLog.log("SwiftUI 嵌客：adaptor delegate 未找到，按类名新建（\(String(describing: type(of: built)))）")
        } else {
            SBDiagLog.log("SwiftUI 嵌客：adaptor delegate 未找到（递归＋类名都未果，不挡窗口）")
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

    // —— 5. WindowGroup 内容 → 根视图 ————————————————————
    // 0.2.33：0.2.32 真机 Husk 四回同因失败——WindowGroup 的 content 子项不是
    // 裸闭包，而是 SwiftUI 内部类型 WindowGroupRootContent<Content>（init 收
    // 的是 lazyContent 闭包，Husk 2.0 二进制 mangled 名
    // WindowGroupV2id5title11lazyContent… 为证；RootContent 的字段表在
    // SwiftUICore 里，客二进制里没有，只能运行时 Mirror 发现、不能硬编码）。
    // 修法：递归钻取——子项本身是 View 即取（RootContent 就是内容树）；不是则
    // 钻进去找闭包（调后须是 View）或已建好的 View；title 跳过（Text 也是
    // View，不能当根视图）；深度 ≤3；每步记日志，找不到只返回 false。
    var rootView: (any View)?
    for child in Mirror(reflecting: group).children {
        let label = child.label ?? "(无标签)"
        let childTypeName = String(describing: type(of: child.value))
        SBDiagLog.log("SwiftUI 嵌客：WindowGroup 子项 \(label)：\(childTypeName)")
        guard label != "title" else { continue }
        if let view = findRootView(in: child.value, depth: 0, path: label) {
            rootView = view
            SBDiagLog.log("SwiftUI 嵌客：根视图类型 \(String(describing: type(of: view)))（子项 \(label)）")
            break
        }
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
