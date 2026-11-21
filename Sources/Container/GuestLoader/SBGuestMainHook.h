// SBGuestMainHook.h — 客 App 的 UIApplicationMain 拦截（0.2.27 进程内进客）。
//
// 机制（0.2.30 统一重绑路）：dlopen 客可执行后、跳客 main 前，用
// SBChainedFixupRebind（链式修正感知 GOT 重绑，0.2.28/0.2.29 已证）把客
// 镜像里 UIApplicationMain 的导入槽重绑到替身。两种调用形态都覆盖：
//   ① C 符号 _UIApplicationMain（ObjC main.m 直接调）；
//   ② Swift 覆盖层符号 _$s5UIKit17UIApplicationMain…（Swift @main /
//      @UIApplicationMain 生成的 main 调 UIKit 的 Swift 覆盖层函数，含
//      Flutter Runner——原型 0230：OmoFun Runner 链式 import 序号 41，
//      __DATA_CONST 槽 0x8150，指针格式 6；C 符号在它 import 表里根本没有）。
// 主镜像两种符号都试过、都没槽时，再扫客 Frameworks（调用若在 Framework
// 里，拦截点跟过去；实测 Flutter 的调用在主镜像，Framework 扫是兜底）。
// 判别器：[UIApplication sharedApplication]==nil 时是新鲜进程里的第一遍
// UIApplicationMain（宿主启动、或 main.m 前置路的客），原样转发；非空时是进程内
// 的第二遍（宿主 UIKit 已在跑），拦截并走会话激活，返回 0，不跑第二遍 runloop。
//
// 0.2.30 根因（崩溃报告 SealBox-2026-11-21-000419.ips，nread 0.2.29 真机）：
// 旧路两处都断——① 安装门 SBGuestImageFileReferencesUIApplicationMain 只在
// LC_SYMTAB 未定义符号里找 C 符号，Swift-main 客永远没有它，门一关就报
// “疑似 SwiftUI 客”警告走人（Flutter 客被误标）；② 即便门过了，
// litehook_rebind_symbol 也只改 S_LAZY/S_NON_LAZY 段，链式修正镜像的 __got
// 不在内，静默 no-op。bootstrap 还忽略安装返回值直接跳 main，于是第二遍
// UIApplicationMain 在宿主进程里重初始化，断言 “Dispatch queue already set”
// 崩（与 0.2.24 nread 同因）。0.2.30 起：门删掉（重绑函数按名找槽、没有就
// 是没有，本身就是判定），litehook 在此文件里去掉，安装返回 BOOL，装不上
// 时 bootstrap 走护栏干净失败、不跳 main。
//
// SwiftUI 客：调用点在 SwiftUICore（共享缓存）里，客镜像不直接引用
// UIApplicationMain（任一形态），rebind 够不着——走 App.main 嵌客路
// （SBSwiftUIAppMainHook），不在这里装。
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <setjmp.h>

#import "SBGuestSessionManager.h"
#import "SBGuestUIClassifier.h"

NS_ASSUME_NONNULL_BEGIN

/// 在客镜像里重绑 UIApplicationMain（只在进程内加载路调用；新鲜进程路不装）。
/// context 由 bootstrap 在 dlopen 后填好，hook 触发时传给会话激活；uiType
/// 只用来写 honest 的诊断日志（装不上时写真实客类型，不再误标“疑似 SwiftUI”）。
/// 任一镜像任一符号装上一个槽即返回 YES；全试过都没槽返回 NO（调用方走护栏，
/// 干净失败，不跳 main）。
BOOL SBGuestMainHookInstallForGuestImage(const struct mach_header *guestHeader,
                                         SBGuestMainHookContext *context,
                                         SBGuestUIType uiType);

/// 拦截后的替代实现（C 符号替身）。返回 0 表示客 main 可随即返回。
/// argv 用 UIKit 原签名的可空标注（char * _Nullable * _Nullable），与
/// Swift 侧替身的 argv 类型逐字对应（0.2.30 fixup 1：`char *argv[]` 桥接
/// 成内层非可选指针，Swift 侧 `UnsafeMutablePointer<CChar>?>?` 传不过去，
/// run 44772015671 红于此）。
int SBHookedUIApplicationMain(int argc, char * _Nullable * _Nullable argv,
                              NSString * _Nullable principalClassName,
                              NSString * _Nullable delegateClassName);

/// 本次加载里 hook 是否已触发进程内激活（bootstrap 跳 main 后读：
// 触发过 → main 返回≠退出，不恢复环境、不清收据；未触发 → 按真退出处理）。
BOOL SBGuestMainHookDidActivate(void);

/// 同步激活失败的原因（hook 触发但激活失败时置；未触发或成功时为 nil）。
/// bootstrap 在 main 返回后读到它即按加载失败返回。
/// 注：C 函数返回值不能用 leading 的 `nullable`（Clang 只认方法/属性里的
/// nullable），须用 `_Nullable`（0.2.27 fixup 3，run 44731393741 红于此）。
NSError * _Nullable SBGuestMainHookActivationError(void);

/// 每次跳 main 前复位激活状态（由 bootstrap 调）。
void SBGuestMainHookResetActivationState(void);

#pragma mark - 客 main 收尾的 exit 截获（0.2.33）
//
// 根因（原型 0233，本地真实 Flutter Runner 离线证实）：Swift 生成的 Runner
// main 在覆盖层 UIApplicationMain 返回后无条件调 exit——OmoFun Runner 入口
// 0x4560，覆盖层调用 0x45d4 返回后 `mov x0, x19; bl _exit`，stub 读 __got 槽
// 0x8058 = 链式 import 序号 10 = `_exit`（Mach-O 符号 `_exit` 即 C exit；
// C _exit 是 `__exit`，Runner 没 import 它）；main 里根本没有 ret。替身一返回
// 0，Runner main 就 exit(0)，进程直接退出——不是崩（故无 .ips），bootstrap
// 永远拿不回控制权，0.4 秒补查没机会跑（0.2.32 真机 phoenix 三回全断在
// “替身返回 0”，与此一致）。Husk 2.0 也 import _exit，但它的入口分发器正常
// 返回（0.2.31 真机 guestMain 回到了 bootstrap），无条件 exit 收尾是 Flutter
// @UIApplicationMain 生成 main 的形态。
// 修法：把客主镜像里 `_exit`（有则再加 `__exit`）的导入槽重绑到截获函数；
// 截获时 siglongjmp 回 bootstrap 在跳 main 前设的 setjmp 点，按 main 正常返回
// 走同一分流。截获只在跳 main 的同步调用期间武装——bootstrap 一拿回控制权
// 立即解除；之后客若再调 exit，走原函数（进程退出），不跳回已失效的栈帧。
// 注意：截获绝不能 return——exit 是 noreturn 调用点，其后是下一个函数的代码，
// 返回即落入乱码执行；必须 longjmp。被跳过的帧里的 ARC 对象会漏掉（客正在退
// 出，一次性），不崩。
// 安装不拦加载：客没 import exit 时返回 NO，只记一行（没东西可截获）。

/// 在客主镜像里重绑 `_exit` / `__exit` 到截获。至少一个装上返回 YES。
BOOL SBGuestExitTrapInstallForGuestImage(const struct mach_header * _Nullable guestHeader,
                                         NSString * _Nullable execPath,
                                         NSString *bundleID);

/// 武装 / 解除截获（由 bootstrap 在跳 main 前后调）。
void SBGuestExitTrapArm(void);
void SBGuestExitTrapDisarm(void);

/// 截获到的退出码（仅截获路径有效；bootstrap 在 setjmp 非零分支里读）。
int SBGuestExitTrapCode(void);

/// setjmp 缓冲区（bootstrap 在跳 main 前调 sigsetjmp；截获由此跳回）。
sigjmp_buf *SBGuestExitTrapEnv(void);

NS_ASSUME_NONNULL_END
