// SBExecPathHook.h — 改写可执行路径：让 dyld 的 _NSGetExecutablePath 返回客 App
// 的可执行文件路径。失败返回 NO 并带中文原因，绝不崩溃；用完调用 restore 恢复。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 改写可执行路径。0.2.22 起用 LiveContainer 的 dyld API vtable hook
///（见 SBExecPathHook.m 文件头：打 dyld 的 API vtable，让 dyld 自己把
/// DyldAPI 指针递进 hook，直接改写 DyldConfig 里的 mainExecutablePath；
/// 0x10 是 iOS 15~18.3.2，0x20 是 18.4+，iOS 27 另同步 0x28 处的长度
/// 缓存）；同时直写 CoreFoundation 的进程路径全局量。调完立刻读回一次
/// _NSGetExecutablePath，等于客路径才返回 YES。
BOOL overwriteExecutablePath(NSString *guestExecPath, NSError **error);

/// 恢复：先把 CF 进程路径写回宿主，再用同一条 LC 机制把 dyld 路径写回
/// 宿主（对称调用，不留钩子），并读回校验。
void restoreExecutablePath(void);

NS_ASSUME_NONNULL_END
