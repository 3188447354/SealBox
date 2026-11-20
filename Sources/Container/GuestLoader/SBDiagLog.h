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

/// 进程启动时最先调用（SealboxApp.init）：每次启动一份新日志文件
/// （Documents/Logs/SBStartupLog-<启动时间>-<pid>.txt）；上次最新一份没写
/// 完成标记 = 上次启动没完成就崩了，改名加 -crashed 留档；旧 DiagLogs 目录
/// 的日志一次性迁移过来；保留上限 20 个文件 / 总计 2MB，最旧先删、永不删
/// 当前文件。只跑一次，重复调无操作。任何失败都静默丢弃。
void SBDiagLogBeginRun(void);

/// 记一行（带时间戳），写完立即 fsync，崩了最后一步还在。
/// step 为 NULL 或空串时忽略。写失败静默丢弃。
/// 单文件超过 1MB 后只写一次上限标记行、之后不再追加（只丢日志，不拦启动）。
void SBDiagLogLine(const char *step);

/// 正常启动完成时调用：写完成标记。下次启动看到标记即认作上次正常。
void SBDiagLogMarkStartupComplete(void);

/// dlopen 前调用：在 Logs 里留一个标记文件（内容为客 bundle ID），
//  写完 fsync；dlopen 正常返回（成功或失败）后调 SBDiagLogClearDlopenEntry
/// 清掉。若进程死在 dlopen 里（0.2.23 闪退就是死在这里），标记文件留下来，
/// 下次启动 SBDiagLogBeginRun 会认出来并记一行，不用靠猜。
/// 任何失败都静默丢弃，绝不成为新的崩点。
void SBDiagLogMarkDlopenEntry(const char *guestBundleID);
void SBDiagLogClearDlopenEntry(void);

/// 最近一次启动日志全文：最新崩过的那份（-crashed）优先，其次最新一份；
/// 都没有返回 NULL。返回的是 malloc 出来的 UTF-8 字符串，调用方用完 free。
char *SBDiagLogLatestText(void);

/// 是否有保留下来的崩溃日志（任一 -crashed 文件）。
int SBDiagLogHasCrashedLog(void);

/// 日志文件夹里的文件列表（最新在前），每行 "文件名\t是否崩溃(0/1)\t字节数\n"。
/// 没有文件时返回空串（非 NULL）。返回的是 malloc 出来的字符串，调用方用完 free。
char *SBDiagLogFileList(void);

/// 读日志文件夹里指定文件全文。name 只认 basename（拒绝 ".."、"/"、"\"），
/// 且必须以 SBStartupLog- 开头、以 .txt 结尾；不合规或文件不存在返回 NULL。
/// 返回的是 malloc 出来的 UTF-8 字符串，调用方用完 free。
char *SBDiagLogReadNamedFile(const char *name);

/// 本次启动的日志文件名（不含目录），如 SBStartupLog-2026-11-21-010321-9021.txt。
/// BeginRun 前调返回 NULL。返回的是 malloc 出来的字符串，调用方用完 free。
char *SBDiagLogCurrentFileName(void);

#ifdef __cplusplus
}
#endif

#endif
