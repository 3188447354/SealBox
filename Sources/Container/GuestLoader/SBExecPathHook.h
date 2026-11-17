// SBBundleSpoof.h — 改写可执行路径：让 dyld 的 _NSGetExecutablePath 返回客 App
// 的可执行文件路径。失败返回 NO 并带中文原因，绝不崩溃；用完调用 restore 恢复。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 改写可执行路径。主路径是往 dyld 内部的 process.mainExecutablePath 字段写客路径
///（偏移按系统版本取：iOS 15–18.3.2 为 0x10，18.4+ 为 0x20，iOS 27 另同步 0x28
/// 处的长度缓存）；同时用 litehook 把 _NSGetExecutablePath 挂到返回客路径的替身上，
/// 覆盖直接调该函数的调用方。任一机制成功即返回 YES。
BOOL overwriteExecutablePath(NSString *guestExecPath, NSError **error);

/// 恢复：把 dyld 内部字段写回宿主路径，并让替身改回返回宿主路径。
/// 替身本身不卸载（litehook 契约里没有卸载 API），但恢复后它的行为与原函数一致。
void restoreExecutablePath(void);

NS_ASSUME_NONNULL_END
