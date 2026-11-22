// SBGuestMachOClassList.c — 直接读客 Mach-O 的 __objc_classlist 找类（0.2.42）。
//
// 不走 ObjC 运行时：不调 objc_getClassList（不触发 realizeAllClasses 全量
// 实现化）、不调 NSClassFromString、不调 class_getName（objc4-906 实证：
// class_getName 走 demangledName，可能拿 DemangleCacheLock 并触发懒命名
// 安装——正是读表要绕开的运行时工作）。只做 dyld 查询＋内存读＋指针运算。
//
// 类名解析（逐条对过 Apple objc4-906 源码，见调查报告目录 objc4-objc4-906）：
//   - 类对象布局 struct objc_class { isa(8) superclass(8) cache_t(16) bits }
//     → bits 在 +32。cache_t 为 { _buckets(8) _maybeMask(4) _flags(2) _occupied(2) }。
//   - FAST_DATA_MASK：iOS 真机（TARGET_OS_IPHONE 且非模拟器）
//     0x0f00007ffffffff8UL，其余 0x0f007ffffffffff8UL（objc-runtime-new.h:133-139）。
//   - FAST_IS_RW_POINTER = bit 63（:150-155）：bits 置了该位即已实现化，
//     data 指向堆上的 class_rw_t；否则 data 即 on-disk 的 class_ro_t。
//   - class_rw_t { flags(4) witness(2) index(2) ro_or_rw_ext(8) }（:2304-2312），
//     ro_or_rw_ext 是 PointerUnion<const class_ro_t, class_rw_ext_t>：
//     低位 0 即 ro 指针本身，低位 1 即 rw_ext 指针（首字段就是 ro，:2294-2296）。
//     RW_REALIZED = 1<<31（:76），读 ro 前先验它。
//   - class_ro_t { flags(4) instanceStart(4) instanceSize(4) reserved(4)
//     ivarLayout(8) name }（:1693-1706）→ name 在 +24。
//   - ptrauth（arm64e）：bits 按 safe_ro<Strip> 同款剥签——RO 用
//     process_independent_data 键，RW 用 process_dependent_data 键
//     （objc-config.h:288-293）；只 strip 不 auth，strip 永不 fault，
//     未签名的指针 strip 即恒等。类表项本身是裸指针（readClass 直接解引用，
//     objc-runtime-new.mm:3704 起），不剥签。
//   - 懒命名：部分 Swift 泛型类的 ro->name 为 NULL（mangledName 需 lazy
//     namer 安装，objc-runtime-new.mm:3764 "some Swift generic classes
//     can lazily generate their names"）——读表读不到这种类，跳过并计数；
//     普通非泛型 Swift 类（如 Module.AppDelegate）的 ro->name 在盘上即
//     ObjC 可见名（"Module.AppDelegate"），可直接比对。AppDelegate
//     几乎不可能是泛型类；若命中此边界，返回 NULL＋原因串，干净失败，
//     不回落运行时枚举。
//
// 安全：每次解引用前都验指针落在客镜像地址区间内（ro／name／类对象）；
// 类表地址与条数验界；段数／条数设上限；ro_or_rw_ext 所在的 rw_t 是堆上
// 对象，不按镜像区间验，改验对齐＋RW_REALIZED 标志。任何越界都只跳过
// 该项记 corrupt，不崩进程。
//
// 本文件刻意只用标准 C＋自定 Mach-O 结构（与 <mach-o/loader.h> 同布局，
// 该头在 Linux 构建不存在，故本地定义；iOS 上与系统头逐字段核对过），
// dyld 枚举部分才用 #if __APPLE__ 包起来——于是同一份扫描核心既能编进
// SealBox，也能在 Linux 原型里 #include 进来跑合成 Mach-O 测试件
// （见 ~/workspace/tmp-sb0242verify/proto_macho_classlist/），
// 另有 macOS 复现件（macos_repro/）在真机 runtime 上做读表 vs
// objc_getClassList 的程序化比对。
#include "SBGuestMachOClassList.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>  // snprintf（0.2.42 首轮 CI：隐式声明在工程里是 -Werror）
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#endif

#if defined(__arm64__) || defined(__aarch64__)
#include <ptrauth.h>
#define SB_STRIP_RO_PTR(p) ((uintptr_t)ptrauth_strip((void *)(p), ptrauth_key_process_independent_data))
#define SB_STRIP_RW_PTR(p) ((uintptr_t)ptrauth_strip((void *)(p), ptrauth_key_process_dependent_data))
#else
#define SB_STRIP_RO_PTR(p) ((uintptr_t)(p))
#define SB_STRIP_RW_PTR(p) ((uintptr_t)(p))
#endif

// FAST_DATA_MASK（objc4-906 objc-runtime-new.h:133-139）。
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
#define SB_FAST_DATA_MASK 0x0f00007ffffffff8UL
#else
#define SB_FAST_DATA_MASK 0x0f007ffffffffff8UL
#endif
#define SB_FAST_IS_RW_POINTER 0x8000000000000000UL
#define SB_RW_REALIZED 0x80000000U

#define SB_MH_MAGIC_64 0xfeedfacfU
#define SB_LC_SEGMENT_64 0x19U
#define SB_MAX_NCMDS 512U
#define SB_MAX_CLASSLIST_ENTRIES 1000000U

/// 与 <mach-o/loader.h> 同布局的最小结构（Linux 构建无该头）。
typedef struct {
    uint32_t magic;
    uint32_t cputype;
    uint32_t cpusubtype;
    uint32_t filetype;
    uint32_t ncmds;
    uint32_t sizeofcmds;
    uint32_t flags;
    uint32_t reserved;
} SBMachHeader64;

typedef struct {
    uint32_t cmd;
    uint32_t cmdsize;
} SBLoadCommand;

typedef struct {
    uint32_t cmd;
    uint32_t cmdsize;
    char segname[16];
    uint64_t vmaddr;
    uint64_t vmsize;
    uint64_t fileoff;
    uint64_t filesize;
    int32_t maxprot;
    int32_t initprot;
    uint32_t nsects;
    uint32_t flags;
} SBSegmentCommand64;

typedef struct {
    char sectname[16];
    char segname[16];
    uint64_t addr;
    uint64_t size;
    uint32_t offset;
    uint32_t align;
    uint32_t reloff;
    uint32_t nreloc;
    uint32_t flags;
    uint32_t reserved1;
    uint32_t reserved2;
    uint32_t reserved3;
} SBSection64;

static int SBPtrInRange(uintptr_t p, uintptr_t lo, uintptr_t hi) {
    return p >= lo && p < hi;
}

/// 有界比对：name 须落在 [lo, hi) 内且在区间内有 NUL 结尾；满足才与
/// wanted 做 strcmp。名串在 __TEXT 内，无 NUL 结尾即视为损坏，不读出界。
static int SBBoundedNameEquals(const char *name, uintptr_t lo, uintptr_t hi,
                               const char *wanted) {
    uintptr_t p = (uintptr_t)name;
    if (!SBPtrInRange(p, lo, hi)) {
        return 0;
    }
    size_t remaining = (size_t)(hi - p);
    size_t len = 0;
    // 手写有界 strnlen（strnlen 非 C99，macOS/iOS 有但为可移植手写）。
    while (len < remaining && name[len] != '\0') {
        len++;
    }
    if (len >= remaining) {
        return 0; // 区间内无 NUL 结尾，损坏
    }
    return strcmp(name, wanted) == 0;
}

/// 取一个类对象的 ro 名。返回名指针（借用镜像内存，不持有），或 NULL。
/// *isLazyOut 置 1 表示 ro->name 为空（lazily named，读表无法匹配）；
/// *isCorruptOut 置 1 表示指针越界／结构损坏（跳过该项）。
/// lo/hi：镜像地址区间（ro 与 name 必须落在内；rw_t 在堆上，另验标志）。
static const char *SBClassROName(uintptr_t cls, uintptr_t lo, uintptr_t hi,
                                 int *isLazyOut, int *isCorruptOut) {
    if (isLazyOut) *isLazyOut = 0;
    if (isCorruptOut) *isCorruptOut = 0;
    if (!SBPtrInRange(cls, lo, hi) || cls + 40 < cls) {
        if (isCorruptOut) *isCorruptOut = 1;
        return NULL;
    }
    // bits 在类对象 +32（isa 8 + superclass 8 + cache 16）。
    uintptr_t bits = *(const uintptr_t *)(cls + 32);
    uintptr_t ro = 0;
    if (bits & SB_FAST_IS_RW_POINTER) {
        // 已实现化：bits 是签过名的堆上 rw_t 指针，剥签（RW 键）再掩码。
        uintptr_t data = SB_STRIP_RW_PTR(bits) & SB_FAST_DATA_MASK;
        if (data < 4096 || (data & 7U) != 0) {
            if (isCorruptOut) *isCorruptOut = 1;
            return NULL;
        }
        uint32_t rwFlags = *(const uint32_t *)data;
        if ((rwFlags & SB_RW_REALIZED) == 0) {
            // RW 位已置但 RW_REALIZED 未置：与运行时约定不符，退回 ro 解读。
            ro = SB_STRIP_RO_PTR(bits) & SB_FAST_DATA_MASK;
        } else {
            // ro_or_rw_ext 在 rw_t +8（flags 4 + witness 2 + index 2）。
            uintptr_t v = *(const uintptr_t *)(data + 8);
            if (v & 1U) {
                // rw_ext：首字段即 ro（PointerUnion T2，低位 1）。
                uintptr_t rwe = SB_STRIP_RO_PTR(v & ~1UL);
                if (rwe < 4096 || (rwe & 7U) != 0) {
                    if (isCorruptOut) *isCorruptOut = 1;
                    return NULL;
                }
                ro = SB_STRIP_RO_PTR(*(const uintptr_t *)rwe);
            } else {
                ro = SB_STRIP_RO_PTR(v);
            }
        }
    } else {
        // 未实现化：bits 即 on-disk ro 指针（剥签 RO 键再掩码）。
        ro = SB_STRIP_RO_PTR(bits) & SB_FAST_DATA_MASK;
    }
    if (ro == 0 || !SBPtrInRange(ro, lo, hi)) {
        if (isCorruptOut) *isCorruptOut = 1;
        return NULL;
    }
    // name 在 ro +24（flags/instanceStart/instanceSize/reserved 16 +
    // ivarLayout/nonMetaclass 8）。
    const char *name = *(const char *const *)(ro + 24);
    if (!name) {
        if (isLazyOut) *isLazyOut = 1;
        return NULL;
    }
    if (!SBPtrInRange((uintptr_t)name, lo, hi)) {
        if (isCorruptOut) *isCorruptOut = 1;
        return NULL;
    }
    return name;
}

void *SBGuestMachOClassScanImage(const void *imageBase, long slide,
                                 const char *wantedName,
                                 SBGuestMachOClassScanStats *stats) {
    if (stats) {
        stats->classesScanned = 0;
        stats->nullNameCount = 0;
        stats->corruptCount = 0;
        stats->foundClassList = 0;
    }
    if (!imageBase || !wantedName || wantedName[0] == '\0') {
        return NULL;
    }
    const SBMachHeader64 *header = (const SBMachHeader64 *)imageBase;
    if (header->magic != SB_MH_MAGIC_64) {
        return NULL; // 非 64 位 Mach-O
    }
    if (header->ncmds == 0 || header->ncmds > SB_MAX_NCMDS) {
        return NULL;
    }
    uintptr_t base = (uintptr_t)imageBase;
    uintptr_t lo = (uintptr_t)-1;
    uintptr_t hi = 0;
    uintptr_t listAddr = 0;
    uint64_t listSize = 0;
    int foundList = 0;
    // 走一遍 LC_SEGMENT_64：算镜像地址区间，找 __objc_classlist 段
    //（段名不限——新工具链可能把它放 __DATA_CONST）。
    // 游标全程不得越出 load-command 区（header->sizeofcmds），
    // 段内 section 不得出本段命令体——损坏的头只会提前停下，不会读出界。
    uintptr_t cmdsEnd = base + sizeof(SBMachHeader64) + header->sizeofcmds;
    uintptr_t cursor = base + sizeof(SBMachHeader64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cursor + sizeof(SBLoadCommand) > cmdsEnd) {
            return NULL; // 命令区越界，头损坏
        }
        const SBLoadCommand *lc = (const SBLoadCommand *)cursor;
        if (lc->cmdsize < sizeof(SBLoadCommand) ||
            cursor + lc->cmdsize > cmdsEnd) {
            return NULL; // 命令体损坏
        }
        if (lc->cmd == SB_LC_SEGMENT_64) {
            if (lc->cmdsize < sizeof(SBSegmentCommand64)) {
                return NULL;
            }
            const SBSegmentCommand64 *seg = (const SBSegmentCommand64 *)cursor;
            if (seg->nsects > (lc->cmdsize - sizeof(SBSegmentCommand64)) / sizeof(SBSection64)) {
                return NULL; // section 数超出命令体，损坏
            }
            // __PAGEZERO（vmaddr 0、vmsize 4GB、未映射）不进地址区间，
            // 否则区间下沿会被拉到 slide，越界检查失效。
            if (strncmp(seg->segname, "__PAGEZERO", 16) != 0) {
                // vmaddr 是链接期地址，运行时地址 = vmaddr + slide。
                uint64_t segLo = seg->vmaddr + (uint64_t)slide;
                uint64_t segHi = segLo + seg->vmsize;
                if (seg->vmsize > 0 && segLo < (uint64_t)lo) {
                    lo = (uintptr_t)segLo;
                }
                if (seg->vmsize > 0 && segHi > (uint64_t)hi) {
                    hi = (uintptr_t)segHi;
                }
            }
            uintptr_t sectCursor = cursor + sizeof(SBSegmentCommand64);
            for (uint32_t j = 0; j < seg->nsects; j++) {
                const SBSection64 *sect = (const SBSection64 *)sectCursor;
                if (strncmp(sect->sectname, "__objc_classlist", 16) == 0) {
                    listAddr = (uintptr_t)(sect->addr + (uint64_t)slide);
                    listSize = sect->size;
                    foundList = 1;
                }
                sectCursor += sizeof(SBSection64);
            }
        }
        cursor += lc->cmdsize;
    }
    if (!foundList || listAddr == 0 || listSize == 0) {
        return NULL;
    }
    if (stats) {
        stats->foundClassList = 1;
    }
    uint64_t entryCount = listSize / sizeof(uintptr_t);
    if (entryCount == 0 || entryCount > SB_MAX_CLASSLIST_ENTRIES) {
        return NULL; // 条数离谱，疑似损坏
    }
    // 类表本身必须落在镜像区间内（含末项），否则不读。
    if (!SBPtrInRange(listAddr, lo, hi) ||
        listAddr + entryCount * sizeof(uintptr_t) < listAddr ||
        listAddr + entryCount * sizeof(uintptr_t) > hi) {
        return NULL;
    }
    const uintptr_t *entries = (const uintptr_t *)listAddr;
    for (uint64_t i = 0; i < entryCount; i++) {
        uintptr_t cls = entries[i];
        if (stats) {
            stats->classesScanned++;
        }
        if (cls == 0 || !SBPtrInRange(cls, lo, hi)) {
            if (stats) {
                stats->corruptCount++;
            }
            continue;
        }
        int isLazy = 0, isCorrupt = 0;
        const char *name = SBClassROName(cls, lo, hi, &isLazy, &isCorrupt);
        if (isLazy) {
            if (stats) {
                stats->nullNameCount++;
            }
            continue;
        }
        if (isCorrupt || !name) {
            if (stats) {
                stats->corruptCount++;
            }
            continue;
        }
        if (SBBoundedNameEquals(name, lo, hi, wantedName)) {
            return (void *)cls;
        }
    }
    return NULL;
}

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#include <unistd.h>

static char g_classListFailureReason[256];

/// 规范化路径：realpath 解符号链接（/var → /private/var），
// 失败时回落原串（文件已不存在时 realpath 不可用，不因此判死刑）。
static void SBGuestRealPath(const char *path, char *out, size_t outSize) {
    if (!path || !out || outSize == 0) {
        if (out && outSize > 0) out[0] = '\0';
        return;
    }
    char resolved[PATH_MAX];
    if (realpath(path, resolved) != NULL) {
        (void)snprintf(out, outSize, "%s", resolved);
    } else {
        (void)snprintf(out, outSize, "%s", path);
    }
}

/// dyld 镜像是否属于本客：路径等于客可执行，或在客 .app 包内。
static int SBGuestImageIsInGuest(const char *imagePath, const char *guestExecReal,
                                 const char *guestAppReal) {
    if (!imagePath || imagePath[0] == '\0') {
        return 0;
    }
    char imageReal[PATH_MAX];
    SBGuestRealPath(imagePath, imageReal, sizeof(imageReal));
    if (guestExecReal && guestExecReal[0] != '\0' &&
        strcmp(imageReal, guestExecReal) == 0) {
        return 1;
    }
    if (guestAppReal && guestAppReal[0] != '\0') {
        size_t appLen = strlen(guestAppReal);
        if (strncmp(imageReal, guestAppReal, appLen) == 0 &&
            imageReal[appLen] == '/') {
            return 1;
        }
    }
    return 0;
}

void *SBGuestMachOClassNamedInGuest(const char *className,
                                    const char *guestExecPath,
                                    const char *guestAppPath,
                                    const char **failureReasonOut) {
    if (failureReasonOut) {
        *failureReasonOut = NULL;
    }
    g_classListFailureReason[0] = '\0';
    if (!className || className[0] == '\0' || !guestExecPath || !guestAppPath) {
        return NULL;
    }
    char execReal[PATH_MAX];
    char appReal[PATH_MAX];
    SBGuestRealPath(guestExecPath, execReal, sizeof(execReal));
    SBGuestRealPath(guestAppPath, appReal, sizeof(appReal));
    SBGuestMachOClassScanStats total = {0, 0, 0, 0};
    int anyGuestImage = 0;
    int anyClassList = 0;
    // 两遍：先扫主可执行镜像（精确匹配），再扫包内其他镜像（framework）。
    // 主镜像优先——同名类分属主镜像与 framework 时，取主镜像的。
    for (int pass = 0; pass < 2; pass++) {
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            const char *imageName = _dyld_get_image_name(i);
            if (!imageName) {
                continue;
            }
            char imageReal[PATH_MAX];
            SBGuestRealPath(imageName, imageReal, sizeof(imageReal));
            int isExec = (execReal[0] != '\0' && strcmp(imageReal, execReal) == 0);
            if (pass == 0 && !isExec) {
                continue;
            }
            if (pass == 1 && (isExec || !SBGuestImageIsInGuest(imageName, execReal, appReal))) {
                continue;
            }
            if (pass == 0 && !SBGuestImageIsInGuest(imageName, execReal, appReal)) {
                continue;
            }
            const struct mach_header *header = _dyld_get_image_header(i);
            if (!header) {
                continue;
            }
            anyGuestImage = 1;
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            SBGuestMachOClassScanStats stats = {0, 0, 0, 0};
            void *found = SBGuestMachOClassScanImage(header, (long)slide,
                                                     className, &stats);
            total.classesScanned += stats.classesScanned;
            total.nullNameCount += stats.nullNameCount;
            total.corruptCount += stats.corruptCount;
            if (stats.foundClassList) {
                anyClassList = 1;
            }
            if (found) {
                return found;
            }
        }
    }
    // 未命中：区分“单纯查无此类”与“读表本身失败”，只许后者写原因串。
    const char *reason = NULL;
    if (!anyGuestImage) {
        reason = "客镜像未在 dyld 列表里（dlopen 后应已加载）";
    } else if (!anyClassList) {
        reason = "客镜像无 __objc_classlist 段（非常规 Mach-O 布局）";
    } else if (total.corruptCount > 0) {
        (void)snprintf(g_classListFailureReason, sizeof(g_classListFailureReason),
                       "类表含 %u 个越界／损坏项，读表未命中",
                       total.corruptCount);
        reason = g_classListFailureReason;
    } else if (total.nullNameCount > 0) {
        (void)snprintf(g_classListFailureReason, sizeof(g_classListFailureReason),
                       "查无此类（另有 %u 个类名未安装：lazily named Swift 泛型类，读表无法匹配）",
                       total.nullNameCount);
        reason = g_classListFailureReason;
    }
    if (reason && failureReasonOut) {
        *failureReasonOut = reason;
    }
    return NULL;
}
#endif
