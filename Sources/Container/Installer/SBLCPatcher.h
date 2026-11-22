// SBLCPatcher.h — 0.2.17：LiveContainer 打补丁器的接线层（我们自己的代码）。
//
// 真正的打补丁逻辑在同目录 LiveContainer/LCMachOUtils.m（LiveContainer 原样
// 代码，AGPL-3.0，MJ 2026-11-19 16:30 下令直接拿现成的）；这里只做 Swift
// 可调的薄包装，并复刻旧 SBMachOPatcher.h 的两个小助手（读 LC_MAIN 入口
// 偏移、查 LC_ID_DYLIB），名字与旧版一致，调用点不用改。
//
// 0.2.17 与旧打补丁器的关键差别（均来自 LC 的做法）：
//   - LC_MAIN 不动（旧版 0.2.16 去掉它；0.2.16 真机日志证伪了“LC_MAIN 是
//     根因”——LC_MAIN=无仍 errno=1，而 LC 自己的客 dylib 都带 LC_MAIN）。
//   - 注入的启动件路径是 LC 写死的 "@loader_path/../../Tweaks/…"（见
//     LCMachOUtils.m 头注，接线时把件名换成了 SBGuestHooks.dylib）。
//   - 空间不够注入启动件时返回 SB_LC_PATCH_ERR_NO_SPACE（调用方决定：
//     主程序按旧行为报安装失败；appex 记日志继续装）。

#ifndef SB_LC_PATCHER_H
#define SB_LC_PATCHER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 返回码：0 为成功，其余见下（取值与旧 SB_MACHO_PATCH_* 一致，
// SBInstaller.patchError(for:) 的映射不用改语义）。
#define SB_LC_PATCH_OK 0
// I/O 失败：文件打不开、读不出、写不回。
#define SB_LC_PATCH_ERR_IO 1
// 不是 Mach-O 文件。
#define SB_LC_PATCH_ERR_NOT_MACHO 2
// 32 位可执行文件（thin 的 MH_MAGIC，或 fat 包里只有 32 位切片）：不支持。
#define SB_LC_PATCH_ERR_UNSUPPORTED_32BIT 3
// App Store 加密包：LC_ENCRYPTION_INFO / LC_ENCRYPTION_INFO_64 的 cryptid != 0。
#define SB_LC_PATCH_ERR_ENCRYPTED 4
// 没有足够空间注入 LC_LOAD_DYLIB（LC 的 PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER）。
#define SB_LC_PATCH_ERR_NO_SPACE 5
// 非 arm64 / arm64e 架构（如只有 x86_64 切片的 fat 包）。
#define SB_LC_PATCH_ERR_UNSUPPORTED_ARCH 7

/// 0.2.44（B-1）：与 SBLCPatchExecutable 同款，但打补丁前把客 bundleID
/// 置进打补丁器（LCSetPatchGuestBundleID），使 LC_ID_DYLIB 写唯一名
/// "<bundleID>/<basename>"；打完清掉。主程序用它；appex 继续用旧函数
///（不置 bundleID，行为不变——appex 从不被 dlopen，裸名无碰撞）。
int32_t SBLCPatchExecutableForGuest(const char *path, int doInject,
                                    int *seg_mismatch_out,
                                    const char *bundleID);

/// 读 Mach-O 首个 arm64 切片的 LC_ID_DYLIB 安装名（B-3 签名修复门用）。
/// - Returns: 读到时返回 1 并写 *nameOut（NUL 结尾）；否则返回 0。
int SBMachOIDDylibName(const char *path, char *nameOut, size_t nameOutSize);

/// 整包命名空间改写（0.2.44 B-2，0.2.45 修正）：只修主程序不够——Guoguo 的
/// App.framework 与 OmoFun 的 App.framework 安装名同为
/// "@rpath/App.framework/App"，dyld 按安装名去重会串味。本函数把包内
/// 全部 framework 的 LC_ID_DYLIB 改写为每客唯一名；主程序 ID 由 B-1
///（SBLCPatchExecutableForGuest）写唯一名。
/// 唯一名：主程序 "<bundleID>/<basename>"；framework
/// "@rpath/<bundleID>/<Fw>.framework/<Fw>"。
/// 引用绝不能改（0.2.45）：LC_LOAD_DYLIB／WEAK／REEXPORT 的 @rpath 引用
/// 是路径模板，只决定“去哪找文件”，不决定身份；去重靠 LC_ID_DYLIB。
/// 0.2.44 曾把引用同步改成 "@rpath/<bundleID>/<Fw>.framework/<Fw>"，
/// 却既没在磁盘上建 Frameworks/<bundleID>/ 子目录、没移动任何 framework
/// 文件，也没加任何 LC_RPATH——已改的引用按未变的 LC_RPATH 展开永远找
/// 不到文件，4 个客当场 dlopen 失败（Library not loaded；OmoFun 离线
/// 实证：改写前 35/35 引用可解析，改写后 0/35）。引用保持原样
/// "@rpath/<Fw>.framework/<Fw>" 时 dyld 从磁盘正确加载本客文件；另一客
/// 引用同一 framework 名时，按安装名查不到本客的唯一 ID，便按自己的
/// 路径加载，不串味。
/// 改写规则：新串塞得进原命令名域就地写；塞不进且命令表后有空闲（到
/// __text 的空隙）就扩命令、后移命令表；实在改不了就原样留着并记一条
/// 警告（不报错；主程序 ID 实在写不进完整唯一名时退到 6 位 djb2 短名
/// 就地写，仍是每客唯一）。
/// 在主程序打补丁之后、重签之前调（安装与重打补丁两路都要调）。
/// - Parameters:
///   - bundlePath: .app 包路径；execPath: 主可执行文件路径；bundleID: 客 bundleID。
///   - warningsOut: 可为 NULL；非 NULL 时写改不了的命令数（>0 只记日志，不拦安装）。
/// - Returns: 改写过的文件数；<0 表示致命 I/O 错误（包目录读不出）。
int SBLCPatchBundleNamespace(const char *bundlePath, const char *execPath,
                             const char *bundleID, int *warningsOut);

/// 逆向修复 0.2.44 rev 4 的引用改写（0.2.45）：把包内主程序＋全部
/// framework 二进制里所有 "@rpath/<bundleID>/<Fw>.framework/<Fw>" 形式的
/// LC_LOAD_DYLIB／WEAK／REEXPORT 引用改回 "@rpath/<Fw>.framework/<Fw>"；
/// framework 的 LC_ID_DYLIB 保持唯一名不动（修法 A 的终态）。
/// 逆向只缩短字符串，走就地写。调用顺序关键：先跑修正后的
/// SBLCPatchBundleNamespace（只改 ID），再跑本函数。
/// - Returns: 改写过的文件数；<0 表示致命 I/O 错误。
int SBLCRepairRev4Namespace(const char *bundlePath, const char *execPath,
                            const char *bundleID, int *warningsOut);

/// rev 4 损坏的直接指纹（0.2.45）：主程序是否仍有含
/// "@rpath/<bundleID>/" 前缀的 framework 引用。launchApp 门与签名修复门
/// 都认它；逆向修复成功后指纹消失，门自动不再触发。
/// - Returns: 有损坏引用返回 1，否则返回 0（读不到主程序时也返回 0）。
int SBLCNamespaceNeedsRepair(const char *execPath, const char *bundleID);

/// 离线断言（0.2.45）：改写后逐条 "@rpath/<Fw>.framework/<Fw>" 形式的
/// 引用按引用文件的 LC_RPATH 展开必须在包内存在，否则安装／重打补丁拒绝。
/// @rpath/*.dylib 系统库引用不在包内，不查；WEAK 引用只在引用的 framework
/// 随包发布时查（弱引用缺件是 dyld 容忍的合法情形）。
/// 展开用引用文件自己的 LC_RPATH ＋主程序的 LC_RPATH（dyld 解析 framework
/// 引用时主程序 LC_RPATH 也兜底；只用引用文件自己的会把 0.2.43 能开的包误判）。
/// - Parameters:
///   - firstBadOut: 可为 NULL；非 NULL 时写首条未解析引用的原串。
/// - Returns: 未解析的引用条数；0 = 全过；<0 表示致命 I/O 错误。
int SBLCVerifyFrameworkReferences(const char *bundlePath, const char *execPath,
                                  char *firstBadOut, size_t firstBadOutSize);

/// 对一个 Mach-O 可执行文件打补丁（原地修改），做法与 LC 的
/// patchExecAndSignIfNeedWithCompletionHandler（LCAppInfo.m:326-340）一致：
/// 逐个 arm64 切片调 LCPatchExecSlice；doInject 为真时注入启动件
/// （LC_LOAD_DYLIB），为假时写占位命令 0x114514（appex 用）。
/// 加密包在任何修改前拒绝；32 位 / 非 arm64 按码返回。
///
/// - Parameters:
///   - path: 可执行文件路径（thin 包或 fat 包均可；fat 包处理其中全部
///     arm64 / arm64e 切片，与 LC 一致）。
///   - doInject: 是否注入启动件（主程序 YES，appex NO）。
///   - seg_mismatch_out: 可为 NULL；非 NULL 时，若链式修正里的段数与实际
///     段数不一致，置 *seg_mismatch_out = 1（补丁照打、调用方继续装；
///     iOS 27 的绕过未取，见 build log 0.2.17——启动时 dyld 会按原文报错）。
/// - Returns: `SB_LC_PATCH_OK` 为成功，其余为上列错误码。
int32_t SBLCPatchExecutable(const char *path, int doInject,
                            int *seg_mismatch_out);

/// 读 Mach-O 的 LC_MAIN entryoff（打补丁前调：0.2.16 打过的旧文件已没有
/// LC_MAIN，入口偏移须先读出、存进安装记录，供加载器跳入客 main 用）。
/// fat 包取 arm64e 优先、其次首个 arm64 切片（与 SBGuestEntry 的取片
/// 偏好一致）；薄包直接读自身。
/// - Returns: 找到 LC_MAIN 时返回 1 并写 *entryoffOut；否则返回 0
///   （不是 Mach-O、没有 arm64 切片、没有 LC_MAIN 均返回 0，不报错）。
int SBMachOEntryOffset(const char *path, uint64_t *entryoffOut);

/// 检查 Mach-O 文件里每个 arm64 / arm64e 切片是否都有 LC_ID_DYLIB。
/// 打补丁后校验用——dlopen 一个 MH_DYLIB 时 dyld 要求它带 LC_ID_DYLIB，
/// 缺了启动必败。打补丁器在空间实在不够时是静默跳过 LC_ID_DYLIB 的
/// （与 LC 一致），所以调用方打完补丁必须用这个函数校验，缺了就报明确错误。
/// - Returns: 至少一个 arm64 切片、且每个 arm64 切片都有 LC_ID_DYLIB
///   时返回 1；否则返回 0（读不到、不是 Mach-O、没有 arm64 切片、任一
///   切片缺 LC_ID_DYLIB 均返回 0）。
int SBMachOHasIDDylib(const char *path);

/// 全包 arm64e 修正（LC 的 LCPatchAppBundleFixupARM64eSlice 原样调用）：
/// 包内 .dylib 与 framework 可执行文件补 CPU_SUBTYPE_LIB64 标记。
/// 尽力而为：某文件读失败 / 不是 Mach-O 时跳过，不阻塞安装。
void SBLCFixupBundleARM64e(const char *bundlePath);

/// 内核验签（LC 的 checkCodeSignature 原样调用，LCAppInfo.m:378/401
/// 同款）：fcntl F_ADDFILESIGS_RETURN + F_CHECK_LV 直接问内核签名是否
/// 有效。重签后调用——内核说无效就报签失败，不走到 dlopen 才由 dyld 报错。
/// - Returns: 内核认为签名有效返回 1，否则返回 0。
int SBLCCheckCodeSignature(const char *path);

/// 内核验签诊断版（0.2.20）：与 SBLCCheckCodeSignature 同逻辑，但把失败现场
/// 带出来——死在哪一步、errno、内核的 lv_error_message 原话，供诊断日志用。
/// - Parameters:
///   - outStep: 0=通过、1=无 LC_CODE_SIGNATURE 或非 arm64、2=F_ADDFILESIGS_RETURN
///     失败、3=F_CHECK_LV 失败（可传 NULL）。
///   - outErrno: 失败那一步的 errno（可传 NULL）。
///   - outMessage: 内核原话（仅第 3 步有；可传 NULL，传时 outMessageSize 须 >=1）。
/// - Returns: 内核认为签名有效返回 1，否则返回 0。
int SBLCCheckCodeSignatureDetail(const char *path, int *outStep, int *outErrno, char *outMessage, size_t outMessageSize);

#ifdef __cplusplus
}
#endif

#endif // SB_LC_PATCHER_H
