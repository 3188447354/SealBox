// SBBundleSpoof.m — 改写主 Bundle：指令扫描找全局槽位。
//
// 做法（按 research §1.3 第 6 步的描述，从零实现）：
//   读 +[NSBundle mainBundle] / CFBundleGetMainBundle 的机器码，跟踪 adrp+add
//   算出的地址，再看哪条 ldr/ldur 从该地址取指针；用“槽位现值 == 当前主 Bundle”
//   校验命中的槽位，确认无误才写。iOS 17 上加载指令是 ldur（按描述减 4 修正，
//   两个候选都试，现值校验说了算）；iOS 27 的 CFBundleGetMainBundle 优先找
//   第一个 tbz 指令所在的分支。
// 安全原则：只读代码页、只写校验过的 __DATA 槽位；任何一步对不上都返回 NO 带中文原因，绝不猜着写。
#import "SBBundleSpoof.h"

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <string.h>

#import "SBGuestLoader.h"

// 扫描上限：getter 只有几十条指令，1024 字节足够；超了就认失败，不继续往未知代码里扫。
static const size_t SBScanMaxBytes = 1024;
static const uint32_t SBRetInsn = 0xD65F03C0; // ret

static void *g_nsBundleSlot = NULL;
static void *g_originalNSBundle = NULL;
static void *g_cfBundleSlot = NULL;
static void *g_originalCFBundle = NULL;

#pragma mark - ARM64 指令解码（只读扫描）

static uint32_t SBReadInsn(uintptr_t address, size_t index) {
    uint32_t insn = 0;
    memcpy(&insn, (const void *)(address + index * 4), sizeof(insn));
    return insn;
}

/// ADRP：(insn & 0x9F000000) == 0x90000000。返回页内偏移 imm<<12（已符号扩展）。
static BOOL SBDecodeADRP(uint32_t insn, uint8_t *rdOut, int64_t *pageOffsetOut) {
    if ((insn & 0x9F000000u) != 0x90000000u) {
        return NO;
    }
    uint32_t immlo = (insn >> 29) & 0x3;
    uint32_t immhi = (insn >> 5) & 0x7FFFF;
    int64_t imm = (int64_t)((immhi << 2) | immlo);
    if (imm & 0x100000) { // 21 位符号扩展
        imm -= 0x200000;
    }
    if (rdOut) {
        *rdOut = (uint8_t)(insn & 0x1F);
    }
    if (pageOffsetOut) {
        *pageOffsetOut = imm << 12;
    }
    return YES;
}

/// ADD（立即数，64 位）：(insn & 0xFF000000) == 0x91000000。
static BOOL SBDecodeADDImm(uint32_t insn, uint8_t *rnOut, uint8_t *rdOut, uint64_t *addendOut) {
    if ((insn & 0xFF000000u) != 0x91000000u) {
        return NO;
    }
    uint32_t imm12 = (insn >> 10) & 0xFFF;
    uint32_t shift = (insn >> 22) & 0x3;
    if (rnOut) {
        *rnOut = (uint8_t)((insn >> 5) & 0x1F);
    }
    if (rdOut) {
        *rdOut = (uint8_t)(insn & 0x1F);
    }
    if (addendOut) {
        *addendOut = (uint64_t)imm12 << (shift ? 12 : 0);
    }
    return YES;
}

/// MOV（寄存器间复制，ORR rd, xzr, rm）：(insn & 0xFFC00000) == 0xAA000000。
static BOOL SBDecodeMOVReg(uint32_t insn, uint8_t *rmOut, uint8_t *rdOut) {
    if ((insn & 0xFFC00000u) != 0xAA000000u) {
        return NO;
    }
    if (rmOut) {
        *rmOut = (uint8_t)((insn >> 16) & 0x1F);
    }
    if (rdOut) {
        *rdOut = (uint8_t)(insn & 0x1F);
    }
    return YES;
}

/// LDR（无符号偏移，64 位）：(insn & 0xFFC00000) == 0xF9400000，偏移 = imm12*8。
/// LDUR（64 位）：(insn & 0xFFC00000) == 0xF8400000，偏移 = 有符号 9 位立即数。
static BOOL SBDecodeLoad(uint32_t insn, BOOL *isLDUROut, uint8_t *rnOut, int64_t *offsetOut) {
    if ((insn & 0xFFC00000u) == 0xF9400000u) {
        if (isLDUROut) {
            *isLDUROut = NO;
        }
        if (rnOut) {
            *rnOut = (uint8_t)((insn >> 5) & 0x1F);
        }
        if (offsetOut) {
            *offsetOut = (int64_t)(((insn >> 10) & 0xFFF) * 8);
        }
        return YES;
    }
    if ((insn & 0xFFC00000u) == 0xF8400000u) {
        if (isLDUROut) {
            *isLDUROut = YES;
        }
        if (rnOut) {
            *rnOut = (uint8_t)((insn >> 5) & 0x1F);
        }
        if (offsetOut) {
            int64_t imm9 = (int64_t)((insn >> 12) & 0x1FF);
            if (imm9 & 0x100) {
                imm9 -= 0x200;
            }
            *offsetOut = imm9;
        }
        return YES;
    }
    return NO;
}

static BOOL SBIsTBZ(uint32_t insn) {
    return (insn & 0x7F000000u) == 0x36000000u;
}

#pragma mark - 槽位扫描

/// 在一段函数机器码里找存放 expectedValue 的指针槽位。
/// onlyAfterInsnIndex >= 0 时，只接受该条指令之后的 ldr/ldur（iOS 27 的 tbz 分支用）。
/// 命中条件：候选地址经 dladdr 确认落在已加载镜像内、8 字节对齐、现值 == expectedValue。
static BOOL SBFindPointerSlot(uintptr_t functionAddress,
                              void *expectedValue,
                              long onlyAfterInsnIndex,
                              void **slotOut) {
    uintptr_t regValue[32];
    BOOL regValid[32];
    for (int i = 0; i < 32; i++) {
        regValue[i] = 0;
        regValid[i] = NO;
    }
    // 寄存器 31 是 SP，adrp/add 不会以它为目标；其余按出现顺序跟踪。
    size_t insnCount = SBScanMaxBytes / 4;
    for (size_t index = 0; index < insnCount; index++) {
        uint32_t insn = SBReadInsn(functionAddress, index);
        if (insn == SBRetInsn) {
            break;
        }
        uintptr_t pc = functionAddress + index * 4;
        uint8_t rd = 0;
        int64_t pageOffset = 0;
        if (SBDecodeADRP(insn, &rd, &pageOffset)) {
            regValue[rd] = (pc & ~(uintptr_t)0xFFF) + (uintptr_t)pageOffset;
            regValid[rd] = YES;
            continue;
        }
        uint8_t rn = 0;
        uint64_t addend = 0;
        if (SBDecodeADDImm(insn, &rn, &rd, &addend)) {
            if (rn < 32 && regValid[rn]) {
                regValue[rd] = regValue[rn] + (uintptr_t)addend;
                regValid[rd] = YES;
            }
            continue;
        }
        uint8_t rm = 0;
        if (SBDecodeMOVReg(insn, &rm, &rd)) {
            if (rm < 32 && regValid[rm]) {
                regValue[rd] = regValue[rm];
                regValid[rd] = YES;
            }
            continue;
        }
        BOOL isLDUR = NO;
        int64_t offset = 0;
        if (SBDecodeLoad(insn, &isLDUR, &rn, &offset)) {
            if (onlyAfterInsnIndex >= 0 && (long)index <= onlyAfterInsnIndex) {
                continue;
            }
            if (rn >= 32 || !regValid[rn]) {
                continue;
            }
            uintptr_t base = regValue[rn];
            // 候选槽位：ldr/ldur 的 base+offset；ldur 时按 research 描述再试一个减 4 的候选。
            uintptr_t candidates[2];
            candidates[0] = base + (uintptr_t)offset;
            size_t candidateCount = 1;
            if (isLDUR) {
                candidates[1] = base + (uintptr_t)offset - 4;
                candidateCount = 2;
            }
            for (size_t c = 0; c < candidateCount; c++) {
                uintptr_t slot = candidates[c];
                if ((slot % 8) != 0 || slot < 0x10000) {
                    continue;
                }
                Dl_info info;
                if (dladdr((const void *)slot, &info) == 0) {
                    continue; // 不在已加载镜像内，不读，避免野指针崩溃
                }
                void *currentValue = *(void **)slot;
                if (currentValue == expectedValue) {
                    *slotOut = (void *)slot;
                    return YES;
                }
            }
            continue;
        }
    }
    return NO;
}

/// 在函数机器码里找第一条 tbz 指令的下标，找不到返回 -1。
static long SBFindFirstTBZIndex(uintptr_t functionAddress) {
    size_t insnCount = SBScanMaxBytes / 4;
    for (size_t index = 0; index < insnCount; index++) {
        uint32_t insn = SBReadInsn(functionAddress, index);
        if (insn == SBRetInsn) {
            break;
        }
        if (SBIsTBZ(insn)) {
            return (long)index;
        }
    }
    return -1;
}

static NSError *SBSpoofError(NSString *message) {
    return SBGuestLoaderErrorMake(SBGuestLoaderErrorSpoofFailed,
                                  @"加载客 App",
                                  message,
                                  @"该客 App 与当前系统版本不兼容，请换个版本重试");
}

#pragma mark - 对外接口

BOOL overwriteMainNSBundle(NSBundle *guestBundle, NSError **error) {
    if (!guestBundle) {
        if (error) {
            *error = SBSpoofError(@"改写主 Bundle 失败：客 Bundle 为空");
        }
        return NO;
    }
    // 类方法须在元类上取实现（class_getMethodImplementation 只查实例方法）。
    Method method = class_getClassMethod([NSBundle class], @selector(mainBundle));
    IMP implementation = method ? method_getImplementation(method) : NULL;
    if (!implementation) {
        if (error) {
            *error = SBSpoofError(@"改写主 Bundle 失败：找不到 NSBundle.mainBundle 的实现");
        }
        return NO;
    }
    void *expectedValue = (__bridge void *)[NSBundle mainBundle];
    void *slot = NULL;
    if (!SBFindPointerSlot((uintptr_t)implementation, expectedValue, -1, &slot)) {
        if (error) {
            *error = SBSpoofError(@"改写主 Bundle 失败：在 NSBundle.mainBundle 里找不到主 Bundle 槽位");
        }
        return NO;
    }
    g_nsBundleSlot = slot;
    g_originalNSBundle = expectedValue;
    *(void **)slot = (__bridge void *)guestBundle;
    // 自检：改完再读一次，确认 mainBundle 确实变成了客 Bundle。
    if ((__bridge void *)[NSBundle mainBundle] != (__bridge void *)guestBundle) {
        *(void **)slot = expectedValue;
        g_nsBundleSlot = NULL;
        g_originalNSBundle = NULL;
        if (error) {
            *error = SBSpoofError(@"改写主 Bundle 失败：写入后校验不一致");
        }
        return NO;
    }
    return YES;
}

BOOL overwriteMainCFBundle(NSBundle *guestBundle, NSError **error) {
    if (!guestBundle) {
        if (error) {
            *error = SBSpoofError(@"改写主 Bundle 失败：客 Bundle 为空");
        }
        return NO;
    }
    uintptr_t functionAddress = (uintptr_t)&CFBundleGetMainBundle;
    if (functionAddress == 0) {
        if (error) {
            *error = SBSpoofError(@"改写主 Bundle 失败：找不到 CFBundleGetMainBundle");
        }
        return NO;
    }
    void *expectedValue = (void *)CFBundleGetMainBundle();
    void *slot = NULL;
    BOOL found = NO;
    NSInteger majorVersion = [[NSProcessInfo processInfo] operatingSystemVersion].majorVersion;
    if (majorVersion >= 27) {
        // iOS 27：优先找第一个 tbz 指令之后的分支里的槽位；找不到再全函数重扫。
        long tbzIndex = SBFindFirstTBZIndex(functionAddress);
        if (tbzIndex >= 0) {
            found = SBFindPointerSlot(functionAddress, expectedValue, tbzIndex, &slot);
        }
    }
    if (!found) {
        found = SBFindPointerSlot(functionAddress, expectedValue, -1, &slot);
    }
    if (!found) {
        if (error) {
            *error = SBSpoofError(@"改写主 Bundle 失败：在 CFBundleGetMainBundle 里找不到主 Bundle 槽位");
        }
        return NO;
    }
    g_cfBundleSlot = slot;
    g_originalCFBundle = expectedValue;
    *(void **)slot = (__bridge void *)guestBundle;
    if ((void *)CFBundleGetMainBundle() != (__bridge void *)guestBundle) {
        *(void **)slot = expectedValue;
        g_cfBundleSlot = NULL;
        g_originalCFBundle = NULL;
        if (error) {
            *error = SBSpoofError(@"改写主 Bundle 失败：写入后校验不一致");
        }
        return NO;
    }
    return YES;
}

void restoreMainNSBundle(void) {
    if (g_nsBundleSlot && g_originalNSBundle) {
        *(void **)g_nsBundleSlot = g_originalNSBundle;
    }
    g_nsBundleSlot = NULL;
    g_originalNSBundle = NULL;
}

void restoreMainCFBundle(void) {
    if (g_cfBundleSlot && g_originalCFBundle) {
        *(void **)g_cfBundleSlot = g_originalCFBundle;
    }
    g_cfBundleSlot = NULL;
    g_originalCFBundle = NULL;
}
