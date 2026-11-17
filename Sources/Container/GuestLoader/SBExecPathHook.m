// SBExecPathHook.m — 改写可执行路径：让 dyld 的 _NSGetExecutablePath 返回客 App 的路径。
//
// 做法（按 research §1.3 第 5 步的描述，从零实现）：
//   主路径：扫描 _NSGetExecutablePath 的实现，跟 adrp+add 找到 dyld 内部
//   process 结构体的地址，按系统版本取 mainExecutablePath 字段偏移
//   （iOS 15–18.3.2 为 0x10，18.4+ 为 0x20，iOS 27 另同步 0x28 处的长度缓存），
//   用“字段现值 == 当前宿主可执行路径”校验命中，确认无误才写客路径。
//   辅路径：用 litehook 把 _NSGetExecutablePath 挂到返回客路径的替身上，
//   覆盖直接调该函数的调用方；_NSGetExecutablePath 的桩（stub）先跟分支跳到 dyld 内的真实现再扫。
// 安全原则：字段现值校验不过就不写；任一机制成功即算成功；用完恢复（见头文件注释）。
#import "SBExecPathHook.h"

#import <dlfcn.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdlib.h>
#import <string.h>

#import "SBGuestLoader.h"
#import "litehook.h"

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
        // LDR（无符号偏移，64 位）/ LDUR（64 位）：从跟踪到的结构体基址取字段
        BOOL isLoad = ((insn & 0xFFC00000u) == 0xF9400000u) ||
                      ((insn & 0xFFC00000u) == 0xF8400000u);
        if (!isLoad) {
            continue;
        }
        uint8_t rn = (uint8_t)((insn >> 5) & 0x1F);
        if (rn >= 32 || !regValid[rn]) {
            continue;
        }
        uintptr_t structBase = regValue[rn];
        uintptr_t field = structBase + fieldOffset;
        if ((field % 8) != 0 || field < 0x10000) {
            continue;
        }
        Dl_info info;
        if (dladdr((const void *)field, &info) == 0) {
            continue;
        }
        const char *currentValue = *(const char **)field;
        if (!currentValue) {
            continue;
        }
        if (strcmp(currentValue, hostExecPath) == 0) {
            *fieldOut = (void *)field;
            if (lengthCacheFieldOut) {
                *lengthCacheFieldOut = structBase + SBExecPathLengthCacheOffset27;
            }
            return YES;
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

    BOOL structWritten = NO;
    BOOL hookInstalled = NO;

    // —— 主路径：写 dyld 内部字段 ————————————————————————————
    size_t fieldOffset = SBExecPathOffsetPre184;
    BOOL syncLength = NO;
    SBExecPathOffsets(&fieldOffset, &syncLength);
    void *functionAddress = dlsym(RTLD_DEFAULT, "_NSGetExecutablePath");
    if (functionAddress) {
        uintptr_t implementation = SBResolveThroughBranch((uintptr_t)functionAddress);
        void *field = NULL;
        size_t lengthCacheField = 0;
        if (SBFindExecPathField(implementation, g_savedHostExecPath, fieldOffset, &field, &lengthCacheField)) {
            free(g_guestExecPath);
            g_guestExecPath = strdup([guestExecPath UTF8String]);
            *(const char **)field = g_guestExecPath;
            if (syncLength) {
                // iOS 27：同步长度缓存。
                *(size_t *)lengthCacheField = strlen(g_guestExecPath);
                g_structLengthCacheField = lengthCacheField;
            }
            g_structField = field;
            structWritten = YES;
        }
    }

    // —— 辅路径：litehook 挂 _NSGetExecutablePath ————————————————————
    if (!g_hookInstalled) {
        void *symbol = NULL;
        const struct mach_header *dyldHeader = SBFindDyldImageHeader();
        if (dyldHeader) {
            symbol = (void *)litehook_find_symbol(dyldHeader, "_NSGetExecutablePath");
        }
        if (!symbol) {
            symbol = dlsym(RTLD_DEFAULT, "_NSGetExecutablePath");
        }
        if (symbol) {
            if (!g_guestExecPath) {
                g_guestExecPath = strdup([guestExecPath UTF8String]);
            }
            litehook_hook_function(symbol, (void *)SBHooked_NSGetExecutablePath);
            g_hookInstalled = YES;
            hookInstalled = YES;
        }
    } else {
        // 替身已装过：只需把客路径换上去。
        free(g_guestExecPath);
        g_guestExecPath = strdup([guestExecPath UTF8String]);
        hookInstalled = YES;
    }

    if (structWritten || hookInstalled) {
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
