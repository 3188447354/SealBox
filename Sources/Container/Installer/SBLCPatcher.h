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
