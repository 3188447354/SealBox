// SBExecPathHook.m — 改写可执行路径：让 dyld 的 _NSGetExecutablePath 返回客 App 的路径。
//
// 做法（按 research §1.3 第 5 步的描述，从零实现）：
//   主路径：扫描 _NSGetExecutablePath 的实现，跟 adrp+add 找到 dyld 内部
//   process 结构体的地址，按系统版本取 mainExecutablePath 字段偏移
//   （iOS 15–18.3.2 为 0x10，18.4+ 为 0x20，iOS 27 另同步 0x28 处的长度缓存），
//   用“字段现值 == 当前宿主可执行路径”校验命中，确认无误才写客路径。
//   辅路径：用 litehook 把 _NSGetExecutablePath 挂到返回客路径的替身上，
//   覆盖直接调该函数的调用方；_NSGetExecutablePath 的桩（stub）先跟分支跳到 dyld 内的真实现再扫。
//   直写：改写 CoreFoundation 的进程路径全局量 *_CFGetProcessPath()（LiveContainer 同款做法）。
// 安全原则：字段现值校验不过就不写；任一机制成功即算成功；用完恢复（见头文件注释）。
//   0.2.5 安全修：扫描器的字段现值读取改用 vm_read_overwrite 安全读——
//   0.2.4 真机日志证明进程死在“主 Bundle 伪装完成”之后、
//   本步两条日志分支（成功/失败）都没出现，即死在 overwriteExecutablePath 内；
//   本步唯一的无保护内存访问就是扫描器里 `*(const char **)field` 后直接 strcmp：
//   iOS 27 的 dyld 实现 pattern 与假设的 adrp+add+LDR 结构访问不符时，
//   跟踪到的“结构体基址”是错的，field 落在某镜像的数据区，
//   那 8 字节当指针解出来是垃圾地址，strcmp 直接读未映射内存 → EXC_BAD_ACCESS。
//   安全读把“读不到”变成可跳过的候选，不再崩。另：长度缓存只在确认是结构体布局时才同步。
#import "SBExecPathHook.h"

#import <dlfcn.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <stdlib.h>
#import <string.h>

#import "SBGuestLoader.h"
#import "SBDiagLog.h"
#import "litehook.h"

// CoreFoundation 私有导出：进程路径全局量的地址（LiveContainer 同款用法）。
extern char **_CFGetProcessPath(void);

// dyld 内部 process.mainExecutablePath 字段偏移（按系统版本，见 research §1.3）。
static const size_t SBExecPathOffsetPre184 = 0x10; // iOS 15–18.3.2
static const size_t SBExecPathOffset184Plus = 0x20; // iOS 18.4+
static const size_t SBExecPathLengthCacheOffset27 = 0x28; // iOS 27 长度缓存

static char *g_savedHostExecPath = NULL;   // 宿主可执行路径（strdup，常驻进程）
static char *g_guestExecPath = NULL;       // 客可执行路径（strdup，恢复时释放）
static void *g_structField = NULL;         // dyld 内部 mainExecutablePath 字段地址
static size_t g_structLengthCacheField = 0; // iOS 27 时长度缓存字段地址（0 表示无）
static BOOL g_hookInstalled = NO;

#pragma mark - 版本与偏移

static void SBExecPathOffsets(size_t *fieldOffsetOut, BOOL *syncLengthOut) {
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    size_t fieldOffset = SBExecPathOffsetPre184;
    if (version.majorVersion > 18 ||
        (version.majorVersion == 18 && version.minorVersion >= 4)) {
        fieldOffset = SBExecPathOffset184Plus;
    }
    BOOL syncLength = (version.majorVersion >= 27);
    if (fieldOffsetOut) {
        *fieldOffsetOut = fieldOffset;
    }
    if (syncLengthOut) {
        *syncLengthOut = syncLength;
    }
}

#pragma mark - 安全读

/// 用 vm_read_overwrite 读本进程内存：读不到返回 NO，绝不崩。
/// 扫描器跟出来的地址可能是错的，直接解引用会 EXC_BAD_ACCESS（0.2.4 真机崩点），
/// 这里把“读不到”变成可跳过的候选。
static BOOL SBReadMemorySafe(uintptr_t address, void *buffer, size_t length) {
    if (address == 0 || buffer == NULL || length == 0) {
        return NO;
    }
    vm_size_t outSize = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)address,
                                         (vm_size_t)length, (vm_address_t)buffer, &outSize);
    return kr == KERN_SUCCESS && outSize == length;
}

/// 安全读一个 C 字符串并与 expected 比对：先安全读指针，再安全读
/// strlen(expected)+1 字节进本地缓冲比对。任何一步读不到都返回 NO。
/// 只读这么多就够了：候选串若与 expected 相等，前 strlen+1 字节（含 NUL）必然相同。
static BOOL SBStringEqualsSafe(uintptr_t stringAddress, const char *expected) {
    if (stringAddress == 0 || expected == NULL) {
        return NO;
    }
    size_t needed = strlen(expected) + 1;
    if (needed < 2 || needed > PATH_MAX) {
        return NO;
    }
    char buffer[PATH_MAX];
    if (!SBReadMemorySafe(stringAddress, buffer, needed)) {
        return NO;
    }
    // 候选串必须恰好在 expected 长度处结束（NUL 在 needed-1 位置）：
    // 只比前缀会误判——候选串比 expected 长一位时，前 needed-1 字节相同、
    // 第 needed 字节不是 NUL；不校验这一位会把前缀当相等。
    if (buffer[needed - 1] != '\0') {
        return NO;
    }
    return strcmp(buffer, expected) == 0;
}

#pragma mark - 桩跟随与扫描

/// _NSGetExecutablePath 在 libdyld 里只是一条跳往 dyld 的桩：跟一条无条件分支 B 到真实现。
static uintptr_t SBResolveThroughBranch(uintptr_t address) {
    uint32_t insn = 0;
    memcpy(&insn, (const void *)address, sizeof(insn));
    if ((insn & 0x7C000000u) == 0x14000000u) { // B
        int32_t imm26 = (int32_t)(insn & 0x03FFFFFFu);
        if (imm26 & 0x02000000) {
            imm26 -= 0x04000000;
        }
        return address + (uintptr_t)(imm26 * 4);
    }
    return address;
}

/// 扫描 _NSGetExecutablePath 的真实现，找 mainExecutablePath 字段。
/// 校验：字段地址须落在已加载镜像内、现值字符串须等于宿主可执行路径。
/// 字段候选有两个来源：① 指令自身的偏移（LDR 无符号偏移 imm12*8、LDUR 有符号 imm9），
/// ② 硬编码的字段偏移（0.2.0 的假设，作兜底）；两个都用安全读校验，命中才返回。
/// lengthCacheFieldOut 只在命中①且偏移等于已知结构体字段偏移时才填（即确认是结构体布局），
/// 否则填 0——全局量布局下 structBase+0x28 不是长度缓存，写它会破坏相邻数据。
static BOOL SBFindExecPathField(uintptr_t functionAddress,
                                const char *hostExecPath,
                                size_t fieldOffset,
                                void **fieldOut,
                                size_t *lengthCacheFieldOut) {
    uintptr_t regValue[32];
    BOOL regValid[32];
    for (int i = 0; i < 32; i++) {
        regValue[i] = 0;
        regValid[i] = NO;
    }
    size_t insnCount = 512 / 4;
    for (size_t index = 0; index < insnCount; index++) {
        uint32_t insn = 0;
        memcpy(&insn, (const void *)(functionAddress + index * 4), sizeof(insn));
        if (insn == 0xD65F03C0) { // ret
            break;
        }
        uintptr_t pc = functionAddress + index * 4;
        // ADRP
        if ((insn & 0x9F000000u) == 0x90000000u) {
            uint8_t rd = (uint8_t)(insn & 0x1F);
            uint32_t immlo = (insn >> 29) & 0x3;
            uint32_t immhi = (insn >> 5) & 0x7FFFF;
            int64_t imm = (int64_t)((immhi << 2) | immlo);
            if (imm & 0x100000) {
                imm -= 0x200000;
            }
            regValue[rd] = (pc & ~(uintptr_t)0xFFF) + (uintptr_t)(imm << 12);
            regValid[rd] = YES;
            continue;
        }
        // ADD（立即数，64 位）
        if ((insn & 0xFF000000u) == 0x91000000u) {
            uint8_t rn = (uint8_t)((insn >> 5) & 0x1F);
            uint8_t rd = (uint8_t)(insn & 0x1F);
            uint32_t imm12 = (insn >> 10) & 0xFFF;
            uint32_t shift = (insn >> 22) & 0x3;
            if (rn < 32 && regValid[rn]) {
                regValue[rd] = regValue[rn] + ((uintptr_t)imm12 << (shift ? 12 : 0));
                regValid[rd] = YES;
            }
            continue;
        }
        // LDR（无符号偏移，64 位）/ LDUR（64 位）：从跟踪到的结构体基址取字段。
        // 0.2.5：不再只信硬编码偏移——先用指令自身的偏移算候选，再用硬编码偏移兜底；
        // 现值一律安全读，读不到就跳过，绝不直接解引用（0.2.4 崩点）。
        BOOL isLDR = ((insn & 0xFFC00000u) == 0xF9400000u);
        BOOL isLDUR = ((insn & 0xFFC00000u) == 0xF8400000u);
        if (!isLDR && !isLDUR) {
            continue;
        }
        uint8_t rn = (uint8_t)((insn >> 5) & 0x1F);
        if (rn >= 32 || !regValid[rn]) {
            continue;
        }
        uintptr_t structBase = regValue[rn];
        int64_t insnOffset;
        if (isLDR) {
            uint32_t imm12 = (insn >> 10) & 0xFFF;
            insnOffset = (int64_t)imm12 << 3;
        } else {
            int64_t imm9 = (int64_t)((insn >> 12) & 0x1FF);
            if (imm9 & 0x100) {
                imm9 -= 0x200;
            }
            insnOffset = imm9;
        }
        int64_t candidates[2] = { insnOffset, (int64_t)fieldOffset };
        for (int c = 0; c < 2; c++) {
            uintptr_t field = structBase + (uintptr_t)candidates[c];
            if ((field % 8) != 0 || field < 0x10000) {
                continue;
            }
            Dl_info info;
            if (dladdr((const void *)field, &info) == 0) {
                continue;
            }
            // 安全读指针，再安全读字符串比对：两步任一失败都跳过，不崩。
            uintptr_t currentValue = 0;
            if (!SBReadMemorySafe(field, &currentValue, sizeof(currentValue))) {
                continue;
            }
            if (currentValue == 0) {
                continue;
            }
            if (SBStringEqualsSafe(currentValue, hostExecPath)) {
                *fieldOut = (void *)field;
                if (lengthCacheFieldOut) {
                    // 只有命中硬编码结构体偏移时，才确认是结构体布局、0x28 是长度缓存。
                    *lengthCacheFieldOut = (candidates[c] == (int64_t)fieldOffset)
                        ? structBase + SBExecPathLengthCacheOffset27 : 0;
                }
                return YES;
            }
        }
    }
    return NO;
}

#pragma mark - 替身函数

/// litehook 替身：替代 _NSGetExecutablePath。恢复后 g_guestExecPath 为 NULL，
/// 替身返回宿主路径，与原函数行为一致（见头文件注释）。
static int SBHooked_NSGetExecutablePath(char *buf, uint32_t *bufsize) {
    const char *path = g_guestExecPath ? g_guestExecPath : g_savedHostExecPath;
    if (!path || !bufsize) {
        return -1;
    }
    size_t needed = strlen(path) + 1;
    if (!buf || *bufsize < needed) {
        *bufsize = (uint32_t)needed;
        return -1;
    }
    strcpy(buf, path);
    return 0;
}

/// 在已加载镜像里找 dyld 自身的 mach_header（镜像名以 /dyld 结尾）。
static const struct mach_header *SBFindDyldImageHeader(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) {
            continue;
        }
        size_t length = strlen(name);
        if (length >= 5 && strcmp(name + length - 5, "/dyld") == 0) {
            return _dyld_get_image_header(i);
        }
    }
    return NULL;
}

#pragma mark - dyld 地址校验

/// 地址是否落在 dyld 的 __TEXT 段内：litehook 找出的符号必须先过这一关，
/// 否则 hook 的 5 条指令会写到错误位置。
static BOOL SBAddressInDyldText(const struct mach_header *dyldHeader, const void *address) {
    if (!dyldHeader || !address) {
        return NO;
    }
    unsigned long textSize = 0;
    uint8_t *textStart = getsegmentdata(dyldHeader, "__TEXT", &textSize);
    if (!textStart || textSize == 0) {
        return NO;
    }
    return (const uint8_t *)address >= textStart &&
           (const uint8_t *)address < textStart + textSize;
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
    // 不能先 free 再 strdup——dyld 内部字段与 CF 全局量正指着这块缓冲，
    // 先 free 会让它们在写回新指针之前短暂指向已释放内存。
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

    BOOL structWritten = NO;
    BOOL hookInstalled = NO;
    BOOL cfWritten = NO;

    // —— 直写：CoreFoundation 的进程路径全局量 —————————————————————
    // LiveContainer 同款做法：_CFGetProcessPath() 指向 CF 内部的进程路径变量，
    // 改写后 CF/NSBundle 侧读到的就是客路径。取不到指针不阻断，后面还有两条路。
    char **cfProcessPath = _CFGetProcessPath();
    if (cfProcessPath && *cfProcessPath) {
        *cfProcessPath = g_guestExecPath;
        cfWritten = YES;
        SBDiagLogLine("客加载：CF 进程路径已改写为客路径");
    }

    // —— 主路径：写 dyld 内部字段 ————————————————————————————
    size_t fieldOffset = SBExecPathOffsetPre184;
    BOOL syncLength = NO;
    SBExecPathOffsets(&fieldOffset, &syncLength);
    SBDiagLogLine("客加载：正在扫描 dyld 可执行路径字段");
    void *functionAddress = dlsym(RTLD_DEFAULT, "_NSGetExecutablePath");
    if (functionAddress) {
        uintptr_t implementation = SBResolveThroughBranch((uintptr_t)functionAddress);
        void *field = NULL;
        size_t lengthCacheField = 0;
        if (SBFindExecPathField(implementation, g_savedHostExecPath, fieldOffset, &field, &lengthCacheField)) {
            *(const char **)field = g_guestExecPath;
            if (syncLength && lengthCacheField != 0) {
                // iOS 27：同步长度缓存。lengthCacheField 为 0 表示命中非结构体布局，
                // 那里不是长度缓存，不写（0.2.5）。
                *(size_t *)lengthCacheField = strlen(g_guestExecPath);
                g_structLengthCacheField = lengthCacheField;
            }
            g_structField = field;
            structWritten = YES;
            SBDiagLogLine("客加载：dyld 内部字段已改写为客路径");
        } else {
            SBDiagLogLine("客加载：字段扫描未命中");
        }
    } else {
        SBDiagLogLine("客加载：找不到 _NSGetExecutablePath 符号");
    }

    // —— 辅路径：litehook 挂 _NSGetExecutablePath ————————————————————
    if (!g_hookInstalled) {
        SBDiagLogLine("客加载：正在安装可执行路径 Hook");
        void *symbol = NULL;
        const struct mach_header *dyldHeader = SBFindDyldImageHeader();
        if (dyldHeader) {
            symbol = (void *)litehook_find_symbol(dyldHeader, "_NSGetExecutablePath");
        }
        if (!symbol) {
            symbol = dlsym(RTLD_DEFAULT, "_NSGetExecutablePath");
        }
        // 0.2.5：符号必须落在 dyld __TEXT 内才挂，否则 5 条指令会写错位置；
        // litehook 的返回值必须检查——以前无条件记“已安装”是错的。
        // 注意 dlsym 兜底可能返回 libdyld 的桩（只有一条 B 指令），
        // 挂它会把 20 字节写出桩外、盖掉相邻代码——宁可跳过，不挂错。
        if (symbol) {
            BOOL symbolOK = (dyldHeader != NULL) && SBAddressInDyldText(dyldHeader, symbol);
            if (!symbolOK) {
                SBDiagLogLine("客加载：Hook 目标不在 dyld __TEXT 内，跳过安装");
                symbol = NULL;
            }
        }
        if (symbol) {
            kern_return_t hookResult = litehook_hook_function(symbol, (void *)SBHooked_NSGetExecutablePath);
            if (hookResult == KERN_SUCCESS) {
                g_hookInstalled = YES;
                hookInstalled = YES;
                SBDiagLogLine("客加载：可执行路径 Hook 已安装");
            } else {
                SBDiagLogLine("客加载：可执行路径 Hook 安装失败（继续启动）");
            }
        }
    } else {
        // 替身已装过：只需把客路径换上去。
        hookInstalled = YES;
    }

    if (structWritten || hookInstalled || cfWritten) {
        return YES;
    }
    if (error) {
        *error = SBGuestLoaderErrorMake(SBGuestLoaderErrorSpoofFailed,
                                        @"加载客 App",
                                        @"改写可执行路径失败：在当前系统版本上找不到 dyld 的可执行路径字段",
                                        @"该客 App 与当前系统版本不兼容，请换个版本重试");
    }
    return NO;
}

void restoreExecutablePath(void) {
    // 先恢复 CF 进程路径，再恢复 dyld 内部字段。
    char **cfProcessPath = _CFGetProcessPath();
    if (cfProcessPath && g_savedHostExecPath) {
        *cfProcessPath = g_savedHostExecPath;
    }
    if (g_structField && g_savedHostExecPath) {
        *(const char **)g_structField = g_savedHostExecPath;
        if (g_structLengthCacheField != 0) {
            *(size_t *)g_structLengthCacheField = strlen(g_savedHostExecPath);
        }
    }
    g_structField = NULL;
    g_structLengthCacheField = 0;
    // 替身不卸载，但 g_guestExecPath 清掉后它返回宿主路径，与原函数一致。
    free(g_guestExecPath);
    g_guestExecPath = NULL;
}
