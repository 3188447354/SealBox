// SBMachOPatcher.h — Mach-O 补丁器：把客 App 可执行文件改造成可在宿主进程内 dlopen 的形态。
//
// 做法（按设计规格 §1.2，0.2.5 对齐 LiveContainer 的 LCPatchExecSlice）：
// __PAGEZERO 改地址/大小；MH_EXECUTE → MH_DYLIB，
// 清 MH_PIE、置 MH_NO_REEXPORTED_DYLIBS；注入一条 LC_LOAD_DYLIB 加载客端 Hook 库；
// 补 LC_RPATH；arm64e 切片 cpusubtype 置位；加密包直接拒绝；
// 0.2.5 新增：插 LC_ID_DYLIB（放加载命令最前，install name 取可执行文件名，
//   空间不足时复用 LC_LOAD_DYLINKER 槽；插不下就跳过，不报错——与 LC 一致）、
//   dylib 去重（重复的 LC_LOAD_DYLIB 等改写为无效命令号 0x114515）、
//   链式修正段数不匹配不再当安装失败（只置 segMismatchOut 标记，继续打补丁与签名，
//   启动时 dyld 会按原文报错；iOS 27 的绕过 v1 没有，见 MODULE_NOTES）。
// 0.2.16 新增：去掉 LC_MAIN——LC_MAIN 是主程序入口命令，dylib 带它 dyld
//   不认（0.2.15 真机：execSeg 修好后 dlopen 仍报 code signature invalid，
//   errno 从 85 变成 1；同一份日志里客 dylib 带 LC_MAIN=在，宿主自带 dylib
//   都没有 LC_MAIN 且能正常加载）。入口偏移不丢：调用方在打补丁前用
//   SBMachOEntryOffset 读出、存进安装记录，加载器跳入客 main 时从记录里取
//   （读不到时回退到读文件 LC_MAIN，见 SBGuestBootstrap）。
//
// 注意：打补丁会使原有代码签名失效，调用方（SBInstaller）打完补丁后必须重签。

#ifndef SB_MACHO_PATCHER_H
#define SB_MACHO_PATCHER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 返回码：0 为成功，其余见下。调用方按码区分失败原因。
#define SB_MACHO_PATCH_OK 0
// I/O 失败：文件打不开、读不出、写不回。
#define SB_MACHO_PATCH_ERR_IO 1
// 不是 Mach-O 文件，或 Mach-O 结构损坏（加载命令越界等）。
#define SB_MACHO_PATCH_ERR_NOT_MACHO 2
// 32 位可执行文件（thin 的 MH_MAGIC，或 fat 包里只有 32 位切片）：不支持。
#define SB_MACHO_PATCH_ERR_UNSUPPORTED_32BIT 3
// App Store 加密包：LC_ENCRYPTION_INFO / LC_ENCRYPTION_INFO_64 的 cryptid != 0。
#define SB_MACHO_PATCH_ERR_ENCRYPTED 4
// 没有足够空间注入 LC_LOAD_DYLIB（加载命令区空闲不足，且复用 LC_LOAD_DYLINKER 空间后仍不足）。
#define SB_MACHO_PATCH_ERR_NO_SPACE 5
// 非 arm64 / arm64e 架构（如只有 x86_64 切片的 fat 包）。
#define SB_MACHO_PATCH_ERR_UNSUPPORTED_ARCH 7
// 打完校验失败：改完后 filetype 不是 MH_DYLIB、或 LC_ID_DYLIB 缺失、
// 或 LC_MAIN 还在（0.2.16 新增，见 SBMachOPatchExecutable 注释）。
#define SB_MACHO_PATCH_ERR_VERIFY 8

// __PAGEZERO 段打补丁后的取值：vmaddr = 0x100000000 - 0x4000，vmsize = 0x4000。
#define SB_MACHO_PATCH_PAGEZERO_VMADDR 0xFFFFC000ULL
#define SB_MACHO_PATCH_PAGEZERO_VMSIZE 0x4000ULL

/// 对一个 Mach-O 可执行文件打补丁（原地修改）。
///
/// - Parameters:
///   - path: 可执行文件路径（thin 包或 fat 包均可；fat 包只处理其中的 arm64 / arm64e 切片）。
///   - hooks_dylib_path: 要注入的 LC_LOAD_DYLIB 路径，例如
///     "@loader_path/../../Tweaks/SBGuestHooks.dylib"。
///   - seg_mismatch_out: 可为 NULL；非 NULL 时，若链式修正里的段数与实际段数不一致，
///     置 *seg_mismatch_out = 1（补丁照打、调用方继续装；启动时 dyld 会按原文报错）。
/// - Returns: `SB_MACHO_PATCH_OK` 为成功，其余为上列错误码。
///   失败时文件不被写入（全部修改先在内存里完成，通过校验后才一次性写回），
///   其中加密检测在任何修改前完成，所以加密包原样不动。
///   同一路径已注入时不重复注入，直接返回成功。
///   只处理小端 arm64 / arm64e；32 位返回 `SB_MACHO_PATCH_ERR_UNSUPPORTED_32BIT`。
///   0.2.16：打完逐切片校验 filetype=MH_DYLIB、LC_ID_DYLIB 在位（id_name
///   给了时）、LC_MAIN 已去掉，任一不符返回 `SB_MACHO_PATCH_ERR_VERIFY`，
///   文件不写回。
int32_t SBMachOPatchExecutable(const char *path, const char *hooks_dylib_path,
                               int *seg_mismatch_out);

/// 读 Mach-O 的 LC_MAIN entryoff（打补丁前调：打补丁会去掉 LC_MAIN，
/// 入口偏移须先读出、存进安装记录，供加载器跳入客 main 用）。
/// fat 包取 arm64e 优先、其次首个 arm64 切片（与 SBGuestEntry 的取片
/// 偏好一致）；薄包直接读自身。
/// - Returns: 找到 LC_MAIN 时返回 1 并写 *entryoffOut；否则返回 0
///   （不是 Mach-O、没有 arm64 切片、没有 LC_MAIN 均返回 0，不报错）。
int SBMachOEntryOffset(const char *path, uint64_t *entryoffOut);

/// 给单个 Mach-O 文件的 arm64e 切片补 CPU_SUBTYPE_LIB64 标记
///（LiveContainer 的 LCPatchMachOFixupARM64eSlice 同款做法，包内 .dylib 与
/// framework 可执行文件用；主可执行文件已由 SBMachOPatchExecutable 处理）。
/// 不是 arm64e、已有 LIB64、不是 Mach-O 时直接返回成功（什么都不改）。
/// - Returns: `SB_MACHO_PATCH_OK` 为成功，`SB_MACHO_PATCH_ERR_IO` 为读写失败。
int32_t SBMachOPatchARM64eFile(const char *path);

/// 检查 Mach-O 文件里每个 arm64 / arm64e 切片是否都有 LC_ID_DYLIB。
/// 0.2.6 新增：打补丁后校验用——dlopen 一个 MH_DYLIB 时 dyld 要求它带
/// LC_ID_DYLIB，缺了启动必败（0.2.5 真机：pip_swift 已是 MH_DYLIB 但
/// 缺 LC_ID_DYLIB，dlopen 报 "MH_DYLIB is missing LC_ID_DYLIB"）。
/// 打补丁器在空间实在不够时是静默跳过 LC_ID_DYLIB 的（与 LC 一致），
/// 所以调用方打完补丁必须用这个函数校验，缺了就报明确错误，别装坏包。
/// - Returns: 至少一个 arm64 切片、且每个 arm64 切片都有 LC_ID_DYLIB
///   时返回 1；否则返回 0（读不到、不是 Mach-O、没有 arm64 切片、
///   任一切片缺 LC_ID_DYLIB 均返回 0）。
int SBMachOHasIDDylib(const char *path);

#ifdef __cplusplus
}
#endif

#endif // SB_MACHO_PATCHER_H
