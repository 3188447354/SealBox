// SBDiagLog.h — 启动诊断日志：纯 C 实现，不依赖 Foundation。
//
// 目的：下次再闪退，不用靠猜——应用启动的每一步都实时写盘刷盘，
// 崩了最后一步还在；下次启动能认出上次崩了，把那份日志留下来。
//
// 防御原则：写日志本身绝不能成为新的崩点——所有调用永不抛错、
// 永不弹框，任何失败（没权限、磁盘满、路径异常）都静默丢弃。
// 线程安全：内部一把互斥锁串行化全部文件操作。
#ifndef SB_DIAG_LOG_H
#define SB_DIAG_LOG_H

#ifdef __cplusplus
extern "C" {
#endif

/// 进程启动时最先调用（SealboxApp.init）：轮转日志——上次的 current
/// 没写完成标记 = 上次启动没完成就崩了，留档到 crashed；无论如何都把
/// 上次的 current 抄一份到 previous；然后清空 current、写第一行。
/// 只跑一次，重复调无操作。任何失败都静默丢弃。
void SBDiagLogBeginRun(void);

/// 记一行（带时间戳），写完立即 fsync，崩了最后一步还在。
/// step 为 NULL 或空串时忽略。写失败静默丢弃。
/// 单文件超过 256KB 后不再追加（只丢日志，不拦启动）。
void SBDiagLogLine(const char *step);

/// 正常启动完成时调用：写完成标记。下次启动看到标记即认作上次正常。
void SBDiagLogMarkStartupComplete(void);

/// 最近一次启动日志全文：崩过的那份（crashed）优先，其次上次的
/// （previous），再其次本次的（current）；都没有返回 NULL。
/// 返回的是 malloc 出来的 UTF-8 字符串，调用方用完 free。
char *SBDiagLogLatestText(void);

/// 上次启动是否崩了（有保留下来的崩溃日志）。
int SBDiagLogHasCrashedLog(void);

#ifdef __cplusplus
}
#endif

#endif
