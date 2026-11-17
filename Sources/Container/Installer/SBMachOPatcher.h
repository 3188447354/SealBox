// SBMachOPatcher.h — Mach-O 补丁器：把客 App 可执行文件改造成可在宿主进程内 dlopen 的形态。
//
// 做法（按设计规格 §1.2）：__PAGEZERO 改地址/大小；MH_EXECUTE → MH_DYLIB，
// 清 MH_PIE、置 MH_NO_REEXPORTED_DYLIBS；注入一条 LC_LOAD_DYLIB 加载客端 Hook 库；
// 补 LC_RPATH；arm64e 切片 cpusubtype 置位；加密包直接拒绝。
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
// LC_DYLD_CHAINED_FIXUPS 的段数与实际 LC_SEGMENT_64 数量不一致。
#define SB_MACHO_PATCH_ERR_SEG_COUNT_MISMATCH 6
// 非 arm64 / arm64e 架构（如只有 x86_64 切片的 fat 包）。
#define SB_MACHO_PATCH_ERR_UNSUPPORTED_ARCH 7

// __PAGEZERO 段打补丁后的取值：vmaddr = 0x100000000 - 0x4000，vmsize = 0x4000。
#define SB_MACHO_PATCH_PAGEZERO_VMADDR 0xFFFFC000ULL
#define SB_MACHO_PATCH_PAGEZERO_VMSIZE 0x4000ULL

/// 对一个 Mach-O 可执行文件打补丁（原地修改）。
///
/// - Parameters:
///   - path: 可执行文件路径（thin 包或 fat 包均可；fat 包只处理其中的 arm64 / arm64e 切片）。
///   - hooks_dylib_path: 要注入的 LC_LOAD_DYLIB 路径，例如
///     "@loader_path/../../Tweaks/SBGuestHooks.dylib"。
/// - Returns: `SB_MACHO_PATCH_OK` 为成功，其余为上列错误码。
///   失败时文件不被写入（全部修改先在内存里完成，通过校验后才一次性写回），
///   其中加密检测在任何修改前完成，所以加密包原样不动。
///   同一路径已注入时不重复注入，直接返回成功。
///   只处理小端 arm64 / arm64e；32 位返回 `SB_MACHO_PATCH_ERR_UNSUPPORTED_32BIT`。
int32_t SBMachOPatchExecutable(const char *path, const char *hooks_dylib_path);

#ifdef __cplusplus
}
#endif

#endif // SB_MACHO_PATCHER_H
