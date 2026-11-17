// SBBundleSpoof.h — 改写主 Bundle：把 NSBundle.mainBundle / CFBundleGetMainBundle
// 指向的 Bundle 槽位换成客 App 的 Bundle。失败返回 NO 并带中文原因，绝不崩溃。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 扫描 +[NSBundle mainBundle] 的实现，找到存放主 Bundle 指针的全局槽位并换成客 Bundle。
/// 成功返回 YES；失败返回 NO，error 为中文原因（阶段：加载客 App）。
BOOL overwriteMainNSBundle(NSBundle *guestBundle, NSError **error);

/// 扫描 CFBundleGetMainBundle 的实现，找到 __mainBundle 槽位并换成客 Bundle。
/// iOS 27 上按 research 描述优先找第一个 tbz 指令所在的分支。
BOOL overwriteMainCFBundle(NSBundle *guestBundle, NSError **error);

/// 把槽位恢复成原来的主 Bundle（客 App 退出时调用；找不到已保存的槽位时什么都不做）。
void restoreMainNSBundle(void);
void restoreMainCFBundle(void);

NS_ASSUME_NONNULL_END
