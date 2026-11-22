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

// 0.2.42：size_t 由本头直接提供（SBDiagLogIsGuestStuckForGuest 的签名用它；
// 此前靠其他头转带，在严格模式编译下会报 unknown type name）。
#include <stddef.h>

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
/// 注意：step 是 const char *——传 NSString 字面量 @"..." 会把对象指针
/// 当 C 串读，只写出 isa 指针的低 5 字节乱码（0.2.31 真机三行乱码的根因，
/// 0.2.32 已把全仓 14 处字面量调用改成 [@"..." UTF8String]）。新调用点
/// 一律传 UTF8String 或 C 串，绝不直接传 @"..."。
/// 0.2.41 全仓审计：215 处调用点只剩 main.m:137 这一处直接传 @"..."（同款
/// 错误重现），已改 C 串；其余均为 UTF8String / C 串 / char * 变量。
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

/// 客 scene delegate willConnect 调用前后调用（0.2.36）：与 dlopen 标记同款。
/// willConnect 里 Swift trap 抓不住（@try/@catch 只能抓 NSException），进程
/// 死在里面时日志只断在“调用…”行之后；有此标记，下次启动能明确报“上次死在
/// willConnect 里（客=…）”，不用靠缺行推断。调用前 Mark、返回/抛异常后 Clear。
/// 0.2.38：标记文件改存 App Group 共享区（<组容器>/SBDiag，与拦截记录同目录；
/// 重装宿主换容器也不丢——标记丢了下次启动就写不出拦截记录、会再死一次）。
/// 写／清标记各记一行诊断日志。dlopen 标记仍在 Logs（只作诊断，不拦启动）。
void SBDiagLogMarkWillConnectEntry(const char *guestBundleID);
void SBDiagLogClearWillConnectEntry(void);

/// 0.2.37：上次启动死在 willConnect 里的客 bundle ID（BeginRun 从残留标记读出、
/// 记在进程内静态区；没有残留标记时返回 ""）。driveSceneManually 用它在本次启动
/// 跳过该客的 willConnect 调用（见下 willConnect 熔断）。
const char *SBDiagLogStaleWillConnectGuest(void);

/// 0.2.37：willConnect 熔断记录（内容两行：客可执行指纹、宿主版本）。死过一次
/// willConnect 的客写入此记录；之后启动：指纹与宿主版本均未变 → 不再调
/// willConnect、干净失败；重装/重导（指纹变）或宿主升级（版本变）→ 记录失效，
/// 自动重试一次。willConnect 成功返回与重装都会清掉记录。任何失败都静默丢弃。
/// 0.2.38：记录改存 App Group 共享区（<组容器>/SBDiag/willconnect-blocked-<bundleID>.txt，
/// 0.2.37 在 Logs 里，重装宿主换容器就丢——本轮彩云 01:04:19 又死在 willConnect
/// 里就是这个原因）。共享区不可用时回落到 Logs（行为与 0.2.37 一致，日志里写明）。
/// 0.2.37 升 0.2.38 不重装时，BeginRun 把 Logs 里残留的记录搬到共享区（目标已
/// 存在时按 mtime 定去留）。写／查／清记录各记一行诊断日志。
void SBDiagLogBlockWillConnectForGuest(const char *guestBundleID, const char *fingerprint, const char *hostVersion);
int SBDiagLogIsWillConnectBlockedForGuest(const char *guestBundleID, const char *fingerprint, const char *hostVersion);
void SBDiagLogClearWillConnectBlockForGuest(const char *guestBundleID);

/// 0.2.42：点开流程分步看门狗（调查报告 §5）。
/// 诚实边界：看门狗解不开已死锁的主线程——主线程卡在非抢占锁／客代码里时
/// 任何主线程 UI 都跑不起来。它能做的是三件事：(1) 死点定位（日志最后
/// 一行即死点步的 entry 行，下次启动报“上次卡在某步”）；(2) 步超时判定
/// （每步有阈值，见 SBDiagLogWatchdogStepBegin）；(3) 兜底重启（主线程
/// 心跳停摆超 5 秒或任一步／全流程超时时，写 WATCHDOG TIMEOUT 行＋
/// 卡死熔断标记后主动 exit(0)，把手机还给用户，绝不静默重试、绝不无限等）。
/// 实现：主线程心跳由主队列 dispatch timer 每 250ms 打点（只写一个
/// volatile 时间戳，不记日志、不碰锁）；看门狗线程每 500ms 检查。
/// 看门狗线程本身只做读时间戳＋写文件＋exit，不调任何 ObjC 运行时 API、
/// 不拿 g_lock 之外的锁、不碰 UIKit——避免看门狗自己成为死锁参与方。
/// 武装／解除：点开流程开始前武装（SBGuestBootstrap 包装器），成功
/// （completeActivation）或失败（failActivation／同步激活失败）时解除；
/// 解除只对同一 bundleID 生效（多客交错点开时不互相解除）。
/// 未武装时 StepBegin／StepEnd／Disarm 均为无操作，不写日志。
void SBDiagLogWatchdogArm(const char *guestBundleID);
void SBDiagLogWatchdogDisarmForGuest(const char *guestBundleID);
/// 看门狗熔断用的客指纹＋宿主版本（武装后、dlopen 前由 bootstrap 补填；
/// 超时写熔断标记时用。指纹格式与 willConnect 指纹同款
/// “可执行文件名|大小|mtime”，但属看门狗熔断记录，两套记录不互通）。
void SBDiagLogWatchdogSetGuestFingerprint(const char *fingerprint, const char *hostVersion);
/// 分步标记：step 为步名（"dlopen"／"hook-install"／"class-resolve"／
/// "delegate-init"／"didFinishLaunching"／"storyboard"／"scene-check"／
/// "willConnect"），timeoutSeconds 为该步阈值（dlopen 10s／类解析 2s／
/// delegate init 3s／didFinishLaunching 5s／storyboard 3s／scene 补查 2s／
/// willConnect 5s；全流程 20s 由武装时起算，不用每步传）。
/// entry/exit 各写一行（带单调时钟毫秒耗时），死在哪步日志即断在哪步。
void SBDiagLogWatchdogStepBegin(const char *step, double timeoutSeconds);
void SBDiagLogWatchdogStepEnd(const char *step);

/// 0.2.42：看门狗卡死熔断记录（内容四行：步名、步耗时秒、客指纹、宿主版本）。
/// 超时时写进熔断目录（与 willConnect 拦截记录同目录，App Group 共享区；
/// 共享区不可用时回落 Logs）。下次点该客前先查：指纹与宿主版本均未变 →
/// 干净失败、不再重进（SBGuestBootstrap 入口处查）；重装／升级（指纹或
/// 版本已变）→ 记录失效、自动重试一次；成功激活一次即清掉记录。
/// 文件名只留 [A-Za-z0-9.-]，其余字符变 '_'，永不含 '/'。
void SBDiagLogMarkStuckGuest(const char *guestBundleID, const char *step, double elapsedSeconds, const char *fingerprint, const char *hostVersion);
/// 该客是否在卡死熔断中（记录在位且指纹与宿主版本均对上）。stepOut 非空时
/// 写进熔断的步名（供干净失败文案用）。查不到／不符返回 0。
int SBDiagLogIsGuestStuckForGuest(const char *guestBundleID, const char *fingerprint, const char *hostVersion, char *stepOut, size_t stepOutSize);
void SBDiagLogClearStuckGuestForGuest(const char *guestBundleID);
/// 上次启动读到的卡死熔断（BeginRun 从熔断目录扫 stuck-*.txt 读出、
/// 记在进程内静态区；没有时返回 ""）。熔断文件本身不删（须留到下次
/// 点该客时由 Is 检查消费或由成功激活清掉），故 BeginRun 每次启动都
/// 会再报一次——一行诊断，不拦启动。
const char *SBDiagLogStaleStuckGuest(void);
const char *SBDiagLogStaleStuckStep(void);

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
