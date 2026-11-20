// SBExecPathHook.m — 改写可执行路径：让 dyld 的 _NSGetExecutablePath 返回客 App 的路径。
//
// 0.2.22：改用 LiveContainer 的 dyld API vtable hook（照搬原码，见“来源”）。
//   0.2.21 真机日志（2026-11-20 12:19:53，客 Husk）证明旧的两条路全断：
//   dyld 内部字段扫描未命中（硬编码偏移在当前 iOS 上失效）；litehook 挂
//   _NSGetExecutablePath 被拒（符号落在 libdyld 桩上、不在 dyld __TEXT 内，
//   跳过是对的）；只有 CF 的 _CFGetProcessPath 改写成功了，但 dyld 的
//   @rpath 解析不走 CF——dlopen 客可执行时 errno=2，找不到
//   @rpath/libqemu-aarch64-softmmu.dylib，dyld 只搜了宿主路径。
//   LC 的办法不内联 hook 符号，而是打 dyld 的 API vtable：先由 dlsym 找
//   _NSGetExecutablePath 的 libdyld 桩，扫 adrp+ldr+ldr 模式定位
//   dyld4::gAPIs、算出 vtable 槽位、vm_protect 改写后恢复；再调一次
//   _NSGetExecutablePath（buf 参数借作新路径），dyld 自己把 DyldAPI 指针
//   递进 hook，由 hook 直接改写 DyldConfig 里的 mainExecutablePath。
//   字段扫描代码已删掉，不留两套互相打架。
//
// 来源（LiveContainer，AGPL-3.0，与仓库根 LICENSE 一致；0.2.17 取
// LCMachOUtils.m 同款做法）：
//   仓库 https://github.com/LiveContainer/LiveContainer.git，
//   本地 checkout ~/workspace/livecontainer-standalone，
//   提交 20ab3513c4b44455622f7ae09584c105491da24f（2026-11-12，main 分支）。
//   取用：
//   - LiveContainer/Tweaks/Dyld.m:199-260 performHookDyldApi（本文件
//     SBPerformHookDyldAPI）
//   - LiveContainer/LCBootstrap.m:179-188 DyldConfig/DyldAPI 结构体（原样）
//   - LiveContainer/LCBootstrap.m:189-218
//     hook__NSGetExecutablePath_overwriteExecPath（本文件
//     SBHookNSGetExecutablePathOverwriteExecPath）
//   - LiveContainer/LCBootstrap.m:220-231 overwriteExecPath（本文件
//     SBOverwriteExecPath）
//   - LiveContainer/utils.m:31-50 aarch64_emulate_adrp、utils.m:111-127
//     aarch64_emulate_adrp_ldr（本文件 static 原样，aarch64_emulate_adrp
//     上方的 PatchfinderUtils 出处注释一并保留）
//   - LiveContainer/dyld_bypass_validation.m 的 ASM 宏与 _builtin_vm_protect
//     trap（本文件 SB_ASM 宏与 _SBBuiltinVMProtect）、
//     LiveContainer/utils.h:21 的 builtin_vm_protect 声明（本文件
//     SBBuiltinVMProtect 声明）
//   - LiveContainer/LCBootstrap.m:375-380：CF _CFGetProcessPath 直写与
//     overwriteExecPath 两处都写（本文件 overwriteExecutablePath 保留 CF 直写）
//
// 与 LC 原文的差异（只限 SealBox 接线必需的改名、文件头与下列各项；
// 原型 ~/workspace/tmp-sb0222verify/execpath_prototype_0222.py 逐行核对）：
//   ① 改名：performHookDyldApi→SBPerformHookDyldAPI、
//     hook__NSGetExecutablePath_overwriteExecPath→
//     SBHookNSGetExecutablePathOverwriteExecPath、overwriteExecPath→
//     SBOverwriteExecPath、builtin_vm_protect→SBBuiltinVMProtect（asm 符号
//     _SBBuiltinVMProtect）、ASM→SB_ASM；aarch64_emulate_* 改为 static。
//   ② assert→优雅失败（LC-ASSERT-1…8，其中 7 分 7a/7b/7c 三处、6 分 6/6b 两处）：
//     义 NDEBUG（pbxproj 全仓 grep 为 0），LC 原文的 assert 在真机上会
//     直接 abort 宿主进程；而加载器第 5 步的契约是尽力而为——“失败只记
//     日志，不阻断启动”（SBGuestBootstrap.m）。所以每一处 assert 都改成
//     记一行诊断 + 返回失败（hook 返回 -1、SBPerformHookDyldAPI 返回
//     false、SBOverwriteExecPath 返回 NO），不崩进程。转换点在代码里以
//     LC-ASSERT-n 标出。
//   ③ 诊断（任务要求）：hook 把用到的字段偏移（0x10/0x20）与 iOS 27 长
//     度缓存是否同步记进文件内静态量；overwriteExecutablePath 在调完后
//     立刻读一次 _NSGetExecutablePath 并记下返回值，必须等于客路径才算
//     成功；CF 直写成功不再单独算成功（0.2.21 教训：CF 写成功了，dyld
//     的 @rpath 仍指向宿主，dlopen 照样 errno=2）。
//   ④ 恢复：不保存 DyldConfig 指针，restoreExecutablePath 里用同一条 LC
//     机制对称调一次 SBOverwriteExecPath（宿主路径），再读回校验。
//   ⑤ LC 原文的已知写法一并保留：hook 里 builtin_vm_protect 传
//     sizeof(dyldConfig)——dyldConfig 是指针，实为 8 字节；vm_protect 按页
//     生效，8 与 0x30 等价，不改。
// 已知 LC 行为（保留，不修）：vtable 槽位被改写的窗口内（一次
// _NSGetExecutablePath 调用），若有别的线程恰好调 _NSGetExecutablePath，
// 会被路由进 hook——它的 buf 会被当成新路径写进 DyldConfig。窗口在主线
// 程一次调用内，LC 同款接受；SealBox 客加载也在主线程串行跑。
// 安全原则：任一机制失败只记日志、不崩；用完恢复（见头文件注释）。
#import "SBExecPathHook.h"

#import <dlfcn.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <os/tpro.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>

#import "SBGuestLoader.h"
#import "SBDiagLog.h"

// CoreFoundation 私有导出：进程路径全局量的地址（LiveContainer 同款用法）。
extern char **_CFGetProcessPath(void);

// —— LiveContainer builtin_vm_protect：直接打 mach_vm_protect trap ———————
// 来源：LiveContainer/dyld_bypass_validation.m（ASM 宏，符号改名）。
#define SB_ASM(...) __asm__(#__VA_ARGS__)
SB_ASM(
.global _SBBuiltinVMProtect \n
_SBBuiltinVMProtect:     \n
    mov x16, #-0xe       \n
    svc #0x80            \n
    ret
);
#undef SB_ASM
// 来源：LiveContainer/utils.h:21（符号改名）。
kern_return_t SBBuiltinVMProtect(mach_port_name_t task, mach_vm_address_t address, mach_vm_size_t size, boolean_t set_max, vm_prot_t new_prot);

static char *g_savedHostExecPath = NULL; // 宿主可执行路径（strdup，常驻进程）
static char *g_guestExecPath = NULL;     // 客可执行路径（strdup，恢复时释放）

// —— LiveContainer hook 诊断（SealBox 追加，见文件头③） ———————————————
// hook 实际写到的 DyldConfig 字段偏移：0x10（iOS 15~18.3.2）或 0x20（18.4+），
// 0 表示 hook 没跑到选字段那一步。
static size_t g_lcExecPathSlotOffset = 0;
// iOS 27 长度缓存（+0x28）是否同步写过。
static BOOL g_lcExecPathLengthSynced = NO;

#pragma mark - LiveContainer: adrp/ldr 仿真（utils.m 原样）

// https://github.com/pinauten/PatchfinderUtils/blob/master/Sources/CFastFind/CFastFind.c
//
//  CFastFind.c
//  CFastFind
//
//  Created by Linus Henze on 2021-10-16.
//  Copyright © 2021 Linus Henze. All rights reserved.
//

/**
 * Emulate an adrp instruction at the given pc value
 * Returns adrp destination
 */
static uint64_t aarch64_emulate_adrp(uint32_t instruction, uint64_t pc) {
    // Check that this is an adrp instruction
    if ((instruction & 0x9F000000) != 0x90000000) {
        return 0;
    }

    // Calculate imm from hi and lo
    int32_t imm_hi_lo = (instruction & 0xFFFFE0) >> 3;
    imm_hi_lo |= (instruction & 0x60000000) >> 29;
    if (instruction & 0x800000) {
        // Sign extend
        imm_hi_lo |= 0xFFE00000;
    }

    // Build real imm
    int64_t imm = ((int64_t) imm_hi_lo << 12);

    // Emulate
    return (pc & ~(0xFFFULL)) + imm;
}

/**
 * Emulate an adrp and ldr instruction at the given pc value
 * Returns destination
 */

static uint64_t aarch64_emulate_adrp_ldr(uint32_t instruction, uint32_t ldrInstruction, uint64_t pc) {
    uint64_t adrp_target = aarch64_emulate_adrp(instruction, pc);
    if (!adrp_target) {
        return 0;
    }

    if ((instruction & 0x1F) != ((ldrInstruction >> 5) & 0x1F)) {
        return 0;
    }

    if ((ldrInstruction & 0xFFC00000) != 0xF9400000) {
        return 0;
    }

    uint32_t imm12 = ((ldrInstruction >> 10) & 0xFFF) << 3;

    // Emulate
    return adrp_target + (uint64_t) imm12;
}

#pragma mark - LiveContainer: DyldConfig/DyldAPI（LCBootstrap.m 原样）

typedef struct {
    void *gap_0x0[2];                  // 0x00, 0x08
    char *mainExecutablePath_old;      // 0x10
    void *gap_0x18;                    // 0x18
    char *mainExecutablePath_18_4;     // 0x20
    size_t mainExecutablePathLen_27_0; // 0x28
} DyldConfig;
typedef struct {
    void *gap_0x0;
    DyldConfig *dyldConfig;
} DyldAPI;

#pragma mark - LiveContainer: dyld API vtable hook（Dyld.m performHookDyldApi 原样）

static bool SBPerformHookDyldAPI(const char* functionName, uint32_t adrpOffset, void** origFunction, void* hookFunction) {

    uint32_t* baseAddr = dlsym(RTLD_DEFAULT, functionName);
    // LC-ASSERT-1：LC 原文 assert(baseAddr != 0)。dlsym 找不到直接返回失败，
    // 不 abort（见文件头②）。
    if (baseAddr == 0) {
        SBDiagLogLine("客加载：dyld vtable Hook 失败：dlsym 找不到函数");
        return false;
    }
    uint32_t* adrpInstPtr = baseAddr + adrpOffset;

    // find the following instruction pattern: 1 adrp + 2 ldr
    // adrp    x8, 0x1e6cf0000
    // ldr     x0, [x8, #0x30]  {dyld4::gAPIs}
    // ldr     x16, [x0]

    static long adrpExtraOffset = -1;
    if(adrpExtraOffset == -1) {
        // let't hope the function is not longer than 200 instructions
        uint32_t* end = baseAddr + 200;
        for(uint32_t* cur = adrpInstPtr;cur < end;++cur) {
            if ((*cur & 0x9f000000) != 0x90000000) {
                continue;
            }
            if ((*(cur+1) & 0xFFC00000) != 0xF9400000) {
                continue;
            }
            if ((*(cur+2) & 0xFFC00000) != 0xF9400000) {
                continue;
            }
            adrpExtraOffset = cur - adrpInstPtr;
            break;
        }
        // LC-ASSERT-2：LC 原文 assert(adrpExtraOffset != -1)。200 条指令内
        // 没找到 adrp+ldr+ldr 模式（dyld 变了）时返回失败，不 abort；下次
        // 调用重扫（adrpExtraOffset 仍为 -1）。
        if (adrpExtraOffset == -1) {
            SBDiagLogLine("客加载：dyld vtable Hook 失败：200 条指令内没找到 adrp+ldr+ldr 模式");
            return false;
        }
    }

    adrpInstPtr += adrpExtraOffset;

    void* gdyldPtr = (void*)aarch64_emulate_adrp_ldr(*adrpInstPtr, *(adrpInstPtr + 1), (uint64_t)adrpInstPtr);

    // LC-ASSERT-3：LC 原文 assert(gdyldPtr != 0)。仿真算不出 gAPIs 地址时返回失败。
    if (gdyldPtr == 0) {
        SBDiagLogLine("客加载：dyld vtable Hook 失败：adrp+ldr 仿真算不出 gAPIs 地址");
        return false;
    }
    // LC-ASSERT-4：LC 原文 assert(*(void**)gdyldPtr != 0)。gAPIs 指针为空时返回失败。
    if (*(void**)gdyldPtr == 0) {
        SBDiagLogLine("客加载：dyld vtable Hook 失败：gAPIs 指针为空");
        return false;
    }
    void* vtablePtr = **(void***)gdyldPtr;

    void* vtableFunctionPtr = 0;
    uint32_t* movInstPtr = adrpInstPtr + 6;

    if((*movInstPtr & 0x7F800000) == 0x52800000) {
        // arm64e, mov imm + add + ldr
        uint32_t imm16 = (*movInstPtr & 0x1FFFE0) >> 5;
        vtableFunctionPtr = vtablePtr + imm16;
    } else if ((*movInstPtr & 0xFFE00C00) == 0xF8400C00) {
        // arm64e, ldr immediate Pre-index 64bit
        uint32_t imm9 = (*movInstPtr & 0x1FF000) >> 12;
        vtableFunctionPtr = vtablePtr + imm9;
    } else {
        // arm64
        uint32_t* ldrInstPtr2 = adrpInstPtr + 3;
        // LC-ASSERT-5：LC 原文 assert((*ldrInstPtr2 & 0xBFC00000) == 0xB9400000)。
        // 第三条不是 LDR（无符号偏移，32 位）时返回失败。
        if ((*ldrInstPtr2 & 0xBFC00000) != 0xB9400000) {
            SBDiagLogLine("客加载：dyld vtable Hook 失败：arm64 分支第三条不是 LDR");
            return false;
        }
        uint32_t size2 = (*ldrInstPtr2 & 0xC0000000) >> 30;
        uint32_t imm12_2 = (*ldrInstPtr2 & 0x3FFC00) >> 10;
        vtableFunctionPtr = vtablePtr + (imm12_2 << size2);
    }


    kern_return_t ret = SBBuiltinVMProtect(mach_task_self(), (mach_vm_address_t)vtableFunctionPtr, sizeof(uintptr_t), false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
    if(ret != KERN_SUCCESS) {
        // LC-ASSERT-6：LC 原文 assert(os_tpro_is_supported())。tpro 不可用
        // 时没法兜底写 vtable，返回失败。
        if (!os_tpro_is_supported()) {
            SBDiagLogLine("客加载：dyld vtable Hook 失败：vm_protect 不通过且 tpro 不可用");
            return false;
        }
        os_thread_self_restrict_tpro_to_rw();
    }
    *origFunction = (void*)*(void**)vtableFunctionPtr;
    *(uint64_t*)vtableFunctionPtr = (uint64_t)hookFunction;
    SBBuiltinVMProtect(mach_task_self(), (mach_vm_address_t)vtableFunctionPtr, sizeof(uintptr_t), false, PROT_READ);
    if(ret != KERN_SUCCESS) {
        // LC-ASSERT-6b：LC 原文此处也有 assert(os_tpro_is_supported())。
        // 第一分支已保证：ret != KERN_SUCCESS 时若 tpro 不可用早已返回，
        // 能走到这里必是 tpro 可用，断言恒真，不再重复检查。
        os_thread_self_restrict_tpro_to_ro();
    }
    return true;
}

#pragma mark - LiveContainer: _NSGetExecutablePath hook（LCBootstrap.m 原样）

static int SBHookNSGetExecutablePathOverwriteExecPath(DyldAPI* dyldApiInstancePtr, char* newPath, uint32_t* bufsize) {
    // LC-ASSERT-7a：LC 原文 assert(dyldApiInstancePtr != 0)。dyld 没递进
    // DyldAPI 指针时返回 -1（像原函数失败那样），不 abort。
    if (dyldApiInstancePtr == 0) {
        SBDiagLogLine("客加载：dyld 路径 Hook 失败：dyld 没递进 DyldAPI 指针");
        return -1;
    }
    DyldConfig* dyldConfig = dyldApiInstancePtr->dyldConfig;
    // LC-ASSERT-7b：LC 原文 assert(dyldConfig != 0)。同上。
    if (dyldConfig == 0) {
        SBDiagLogLine("客加载：dyld 路径 Hook 失败：DyldAPI 里没有 DyldConfig");
        return -1;
    }

    char** mainExecutablePathPtr = 0;
    // mainExecutablePath is at 0x10 for iOS 15~18.3.2, 0x20 for iOS 18.4+
    if(dyldConfig->mainExecutablePath_old != 0 && dyldConfig->mainExecutablePath_old[0] == '/') {
        mainExecutablePathPtr = &(dyldConfig->mainExecutablePath_old);
    } else if (dyldConfig->mainExecutablePath_18_4 != 0 && dyldConfig->mainExecutablePath_18_4[0] == '/') {
        mainExecutablePathPtr = &(dyldConfig->mainExecutablePath_18_4);
    } else {
        // LC-ASSERT-7c：LC 原文 assert(mainExecutablePathPtr != 0)。两个
        // 字段都不是有效路径时返回 -1，不 abort。
        SBDiagLogLine("客加载：dyld 路径 Hook 失败：DyldConfig 里 0x10 与 0x20 都不是有效路径");
        return -1;
    }

    // SealBox 诊断（见文件头③）：记下这次写的是哪个字段。
    g_lcExecPathSlotOffset = (mainExecutablePathPtr == &(dyldConfig->mainExecutablePath_old)) ? 0x10 : 0x20;
    g_lcExecPathLengthSynced = NO;

    kern_return_t ret = SBBuiltinVMProtect(mach_task_self(), (mach_vm_address_t)dyldConfig, sizeof(dyldConfig), false, PROT_READ | PROT_WRITE);
    if(ret != KERN_SUCCESS) {
        // LC-ASSERT-8：LC 原文 assert(os_tpro_is_supported())。tpro 不可用
        // 时直接返回失败，不 abort；可用时按 LC 原样放开 tpro 写。
        if (!os_tpro_is_supported()) {
            SBDiagLogLine("客加载：dyld 路径 Hook 失败：vm_protect 不通过且 tpro 不可用");
            return -1;
        }
        os_thread_self_restrict_tpro_to_rw();
    }
    *mainExecutablePathPtr = newPath;

    // in iOS 27, the length is also cached, it's at +0x28
    if(@available(iOS 27.0, *)) {
        dyldConfig->mainExecutablePathLen_27_0 = strlen(newPath);
        g_lcExecPathLengthSynced = YES;
    }

    if(ret != KERN_SUCCESS) {
        os_thread_self_restrict_tpro_to_ro();
    }

    return 0;
}

// 来源：LiveContainer/LCBootstrap.m overwriteExecPath（原样；返回值由 void
// 改为 BOOL，以便调用方知道 Hook 到底装没装上——LC 原文不检查返回值）。
static BOOL SBOverwriteExecPath(const char *newExecPath) {
    // dyld4 stores executable path in a different place (iOS 15.0 +)
    // https://github.com/apple-oss-distributions/dyld/blob/ce1cc2088ef390df1c48a1648075bbd51c5bbc6a/dyld/DyldAPIs.cpp#L802
    int (*orig__NSGetExecutablePath)(void* dyldPtr, char* buf, uint32_t* bufsize);
    if (!SBPerformHookDyldAPI("_NSGetExecutablePath", 2, (void**)&orig__NSGetExecutablePath, SBHookNSGetExecutablePathOverwriteExecPath)) {
        return NO;
    }
    _NSGetExecutablePath((char*)newExecPath, NULL);
    // put the original function back
    if (!SBPerformHookDyldAPI("_NSGetExecutablePath", 2, (void**)&orig__NSGetExecutablePath, orig__NSGetExecutablePath)) {
        SBDiagLogLine("客加载：dyld vtable Hook 恢复原函数失败（槽位仍指向 Hook）");
        return NO;
    }
    return YES;
}

#pragma mark - 对外接口

BOOL overwriteExecutablePath(NSString *guestExecPath, NSError **error) {
    if (guestExecPath.length == 0) {
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorSpoofFailed,
                                            @"加载客 App",
                                            @"改写可执行路径失败：客路径为空",
                                            @"请重新导入该应用");
        }
        return NO;
    }
    SBDiagLogLine("客加载：正在改写可执行路径");
    // 先记下宿主可执行路径（恢复时要写回去）。
    if (!g_savedHostExecPath) {
        char hostBuffer[PATH_MAX];
        uint32_t hostSize = sizeof(hostBuffer);
        if (_NSGetExecutablePath(hostBuffer, &hostSize) == 0) {
            g_savedHostExecPath = strdup(hostBuffer);
        }
    }
    if (!g_savedHostExecPath) {
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorSpoofFailed,
                                            @"加载客 App",
                                            @"改写可执行路径失败：读不到宿主可执行路径",
                                            @"请重试");
        }
        return NO;
    }
    // 客路径只在未设置时 strdup：同一进程内连续加载时，前一次加载结束
    // 必经 restoreExecutablePath（它会 free 掉），所以这里一定是 NULL；
    // 不能先 free 再 strdup——dyld 内部字段正指着这块缓冲，
    // 先 free 会让它在写回新指针之前短暂指向已释放内存。
    if (!g_guestExecPath) {
        g_guestExecPath = strdup([guestExecPath UTF8String]);
    }
    if (!g_guestExecPath) {
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorSpoofFailed,
                                            @"加载客 App",
                                            @"改写可执行路径失败：客路径分配失败",
                                            @"请重试");
        }
        return NO;
    }

    BOOL cfWritten = NO;

    // —— 直写：CoreFoundation 的进程路径全局量 —————————————————————
    // LiveContainer 同款做法（LCBootstrap.m:375-380）：_CFGetProcessPath()
    // 指向 CF 内部的进程路径变量，改写后 CF/NSBundle 侧读到的就是客路径。
    // 注意：CF 写成功不再单独算成功（0.2.21 教训）——dyld 的 @rpath 解析
    // 不走 CF，CF 写了、dyld 没改，dlopen 照样 errno=2 找不到客的库。
    char **cfProcessPath = _CFGetProcessPath();
    if (cfProcessPath && *cfProcessPath) {
        *cfProcessPath = g_guestExecPath;
        cfWritten = YES;
        SBDiagLogLine("客加载：CF 进程路径已改写为客路径");
    }

    // —— dyld 路径：LiveContainer vtable Hook ———————————————————————
    // 0.2.21 的字段扫描 + litehook 两条路已删（见文件头）；现在只走这一条。
    SBDiagLogLine("客加载：正在安装 dyld 可执行路径 Hook（LiveContainer vtable 方式）");
    g_lcExecPathSlotOffset = 0;
    g_lcExecPathLengthSynced = NO;
    if (!SBOverwriteExecPath(g_guestExecPath)) {
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorSpoofFailed,
                                            @"加载客 App",
                                            @"改写可执行路径失败：dyld 的可执行路径 Hook 未能生效",
                                            @"该客 App 与当前系统版本不兼容，请换个版本重试");
        }
        return NO;
    }

    // —— 读回校验：必须等于客路径才算成功 —————————————————————————
    // Hook 已摘掉（SBOverwriteExecPath 把原函数装回去了），这次读走的是
    // dyld 真实现读 DyldConfig 的结果；读回来的不是客路径，说明 Hook 写
    // 的字段不是真实现读的那个，下一步 dlopen 的 @rpath 仍会指向宿主。
    char verifyBuffer[PATH_MAX];
    uint32_t verifySize = sizeof(verifyBuffer);
    if (_NSGetExecutablePath(verifyBuffer, &verifySize) != 0 ||
        strcmp(verifyBuffer, g_guestExecPath) != 0) {
        SBDiagLogLine([[NSString stringWithFormat:@"客加载：dyld 可执行路径读回校验失败（字段偏移=0x%zx iOS 27 长度缓存=%@ CF 已改写=%@ 读回=%s）", g_lcExecPathSlotOffset, g_lcExecPathLengthSynced ? @"已同步" : @"未同步", cfWritten ? @"是" : @"否", verifyBuffer] UTF8String]);
        if (error) {
            *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorSpoofFailed,
                                            @"加载客 App",
                                            @"改写可执行路径失败：dyld 读回的可执行路径不是客路径",
                                            @"该客 App 与当前系统版本不兼容，请换个版本重试");
        }
        return NO;
    }
    SBDiagLogLine([[NSString stringWithFormat:@"客加载：dyld 可执行路径已改写为客路径（LC vtable Hook：字段偏移=0x%zx iOS 27 长度缓存=%@ CF 已改写=%@）", g_lcExecPathSlotOffset, g_lcExecPathLengthSynced ? @"已同步" : @"未同步", cfWritten ? @"是" : @"否"] UTF8String]);
    return YES;
}

void restoreExecutablePath(void) {
    // 先恢复 CF 进程路径，再用同一条 LC 机制把 dyld 路径写回宿主（对称调用，
    // 不留钩子；SBOverwriteExecPath 内部已把原函数装回去）。
    char **cfProcessPath = _CFGetProcessPath();
    if (cfProcessPath && g_savedHostExecPath) {
        *cfProcessPath = g_savedHostExecPath;
    }
    if (g_savedHostExecPath) {
        g_lcExecPathSlotOffset = 0;
        g_lcExecPathLengthSynced = NO;
        if (SBOverwriteExecPath(g_savedHostExecPath)) {
            char verifyBuffer[PATH_MAX];
            uint32_t verifySize = sizeof(verifyBuffer);
            if (_NSGetExecutablePath(verifyBuffer, &verifySize) != 0 ||
                strcmp(verifyBuffer, g_savedHostExecPath) != 0) {
                SBDiagLogLine([[NSString stringWithFormat:@"客加载：可执行路径恢复后读回仍不是宿主路径（读回=%s）", verifyBuffer] UTF8String]);
            }
        } else {
            SBDiagLogLine("客加载：可执行路径恢复失败（dyld Hook 未生效，CF 路径已恢复）");
        }
    }
    // 0.2.6：先置 NULL 再 free——free 在先时，客线程若在两者之间调
    // _NSGetExecutablePath，会读到已释放的内存。
    char *oldGuestExecPath = g_guestExecPath;
    g_guestExecPath = NULL;
    free(oldGuestExecPath);
}
