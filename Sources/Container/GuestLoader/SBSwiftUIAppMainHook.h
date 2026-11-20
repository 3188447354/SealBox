// SBSwiftUIAppMainHook.h — SwiftUI 客的 App.main 拦截（0.2.28 进程内嵌 App 场景）。
//
// 根因：SwiftUI 客的入口是 App.main()→runApp，进程内第二遍 runApp 在
// SwiftUI 自己里面断言崩（Husk/STV 0.2.27 真机两崩同因）。跳原入口必崩，
// 所以不再跳——dlopen 后、跳客 main 前，把客镜像里对 App.main 的引用重绑到
// 替身 SBHookedAppMain，替身拿到客 App 类型元数据后调 Swift 嵌入函数
// （SBSwiftUIEmbedApp）：建 App 实例、取 WindowGroup 内容视图、包进
// UIHostingController 放进客窗口，跑在宿主 runloop 上。
//
// 机制（原型 0228 第 3 组）：
//   App.main 的真实符号是 _$s7SwiftUI3AppPAAE4mainyyFZ（协议扩展方法，PAAE
//   不是 P4）。Swift 泛型特化调用按 Swift 调用约定把类型元数据当隐式参数传，
//   替身按 (typeMetadata, ...) 签名收——元数据与 witness 表的顺序按调用约定
//   可能不同，替身按首字 kind 校验挑出元数据那一个（元数据首字是小整数
//   kind，witness 表首字是函数指针大地址）。
//   重绑走 SBRebindGuestSymbolForImage（链式修正感知）：链式修正镜像读磁盘
//   文件走链找 __got 槽，传统懒绑定镜像按间接符号表找 __la/__nl_symbol_ptr 槽。
//   litehook_rebind_symbol 不能用——它只改 S_LAZY/S_NON_LAZY 段，链式修正
//   镜像的 __got 不在内（静默 no-op），且它按槽位当前值比对，改不了未绑定的懒槽。
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>

#import "SBGuestSessionManager.h"

NS_ASSUME_NONNULL_BEGIN

/// 在客镜像里重绑 App.main（只在进程内加载的 SwiftUI 客上调；UIKit/Flutter
/// 客走 0.2.27 的 UIApplicationMain 拦截，不动）。
/// context 由 bootstrap 在 dlopen 后填好，替身触发时传给 Swift 嵌入函数。
/// 装上返回 YES；装不上（符号不在客镜像里、指针格式不支持等）返回 NO，
/// 调用方走护栏干净失败，不跳 main。
BOOL SBSwiftUIAppMainHookInstallForGuestImage(const struct mach_header *guestHeader,
                                              SBGuestMainHookContext *context);

/// App.main 的替身。arg0/arg1 是 Swift 调用约定传的两个隐式参数
///（类型元数据与 witness 表，顺序不定）；替身按首字 kind 校验挑元数据，
/// 调 Swift 嵌入函数；嵌入失败时置激活错误并直接返回（不调原 App.main，
/// 客 main 随即返回，bootstrap 按失败处理）。
void SBHookedAppMain(const void *arg0, const void *arg1);

/// 本次加载里 SwiftUI 嵌客是否已激活（bootstrap 跳 main 后读：
/// 触发过 → main 返回≠退出，客在前台运行；未触发 → 按失败处理）。
BOOL SBSwiftUIAppMainHookDidActivate(void);

/// 嵌客失败的原因（替身内嵌入失败时置；未触发或成功时为 nil）。
/// bootstrap 在 main 返回后读到它即按加载失败返回。
NSError * _Nullable SBSwiftUIAppMainHookActivationError(void);

/// 每次跳 main 前复位激活状态（由安装函数调）。
void SBSwiftUIAppMainHookResetActivationState(void);

NS_ASSUME_NONNULL_END
