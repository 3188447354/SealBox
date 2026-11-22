// SBGuestMachOClassList.c — 直接读客 Mach-O 的 __objc_classlist 找类（0.2.43）。
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
//     RW_REALIZED = 1<<31（:76）；0.2.43 更正：RW 位已置即按 rw_t 读
//     ro_or_rw_ext，不再验 RW_REALIZED（见 SBClassROName 根因 B1）。
//   - class_ro_t { flags(4) instanceStart(4) instanceSize(4) reserved(4)
//     ivarLayout(8) name }（:1693-1706）→ name 在 +24。
//   - ptrauth（arm64e）：bits 按 safe_ro<Strip> 同款剥签——RO 用
//     process_independent_data 键，RW 用 process_dependent_data 键
//     （objc-config.h:288-293）；只 strip 不 auth，strip 永不 fault，
//     未签名的指针 strip 即恒等。类表项本身是裸指针（readClass 直接解引用，
//     objc-runtime-new.mm:3704 起），不剥签。
//   - 懒命名：部分 Swift 泛型类的 ro->name 为 NULL（mangledName 需 lazy
//     namer 安装，objc-runtime-new.mm:3764 "some Swift generic classes
//     can lazily generate their names"）——读表读不到这种类，跳过并计数。
//   - 0.2.43 更正（REPORT-0.2.43-investigation.md 根因 A）：普通非泛型
//     Swift 类的 ro->name 在盘上是混淆名（_TtC<modlen><mod><clslen><cls>），
//     "Module.AppDelegate" 只是运行时反混淆后的名字——0.2.42 的注释称
//     “盘上即 ObjC 可见名、可直接比对”是错的，拿反混淆名 strcmp 盘上
//     混淆名永不相等。本版新增纯字符串反混淆（SBSwiftDemangleClassName），
//     原名与反混淆名双比对；AppDelegate 几乎不可能是泛型类，
//     若命中泛型特化边界，解析失败即不匹配，返回 NULL＋原因串，干净失败。
//
// 安全：每次解引用前都验指针落在客镜像地址区间内（ro／name／类对象）；
// 类表地址与条数验界；段数／条数设上限；rw_t 在堆上，改验对齐＋标志，
// 不按镜像区间验；实现化后复制到堆上的 ro 副本（RW_COPIED_RO）经结构
// 校验（对齐＋ro 头三字段合理）后接受，名指针仍须落在镜像内。
// 任何越界都只跳过该项记 corrupt，不崩进程。
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
// 注：SB_RW_REALIZED（1<<31）在 0.2.43 已删——RW 位已置即按 rw_t 读
// ro_or_rw_ext，不再验它（根因 B1）；宏本身随分支一并移除，免得后人误用。

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

/// 有界取类名长度：name 须落在 [lo, hi) 内且在区间内有 NUL 结尾；满足
/// 返回 1 并置 *lenOut（反混淆前先用它验名串，不让 strlen 读出界）。
static int SBNameLengthInRange(const char *name, uintptr_t lo, uintptr_t hi,
                               size_t *lenOut) {
    uintptr_t p = (uintptr_t)name;
    if (!SBPtrInRange(p, lo, hi)) {
        return 0;
    }
    size_t remaining = (size_t)(hi - p);
    size_t len = 0;
    while (len < remaining && name[len] != '\0') {
        len++;
    }
    if (len >= remaining) {
        return 0; // 区间内无 NUL 结尾
    }
    if (lenOut) {
        *lenOut = len;
    }
    return 1;
}

/// 解析一段 "<十进制长度><内容>"（Swift 混淆名的标签段）：*p 前进到内容
/// 之后，内容写进 buf（NUL 结尾）。长度为 0、超长（>1024）、内容越过
/// end、buf 装不下，任一即失败返回 0（不截断拼凑）。
static int SBParseMangledLabel(const char **p, const char *end,
                               char *buf, size_t bufSize) {
    const char *cur = *p;
    if (cur >= end || *cur < '0' || *cur > '9') {
        return 0;
    }
    unsigned long n = 0;
    while (cur < end && *cur >= '0' && *cur <= '9') {
        n = n * 10 + (unsigned long)(*cur - '0');
        if (n > 1024) {
            return 0;
        }
        cur++;
    }
    if (n == 0 || (size_t)(end - cur) < n) {
        return 0;
    }
    if (n + 1 > bufSize) {
        return 0;
    }
    memcpy(buf, cur, n);
    buf[n] = '\0';
    *p = cur + n;
    return 1;
}

/// 0.2.43（根因 A）：纯字符串 Swift v1 类名反混淆——无锁、无运行时调用，
/// 与运行时反混淆结果逐字相同（4 个真实值已核对）。
/// 接受：_TtC<modlen><mod><clslen><cls> → "mod.cls"；
///      _TtCC<modlen><mod><outerlen><outer><innerlen><inner> → "mod.outer.inner"；
///      $s<modlen><mod><clslen><cls>C → "mod.cls"。
/// 泛型特化（_TtGC…／$s…G 等含泛型实参的）与私有嵌套名（P33_…）不展开，
/// 解析失败即返回 0（不匹配、不崩）。成功返回 1，结果写进 out（NUL 结尾）。
static int SBSwiftDemangleClassName(const char *mangled, char *out, size_t outSize) {
    if (!mangled || !out || outSize < 2) {
        return 0;
    }
    size_t mlen = strlen(mangled);
    const char *end = mangled + mlen;
    const char *p = mangled;
    int nested = 0;  // _TtCC：模块.外层.内层
    int dollarS = 0; // $s…C：Swift 5 形，末尾须恰好一个 'C'
    if (strncmp(mangled, "_TtCC", 5) == 0) {
        p += 5;
        nested = 1;
    } else if (strncmp(mangled, "_TtC", 4) == 0) {
        p += 4;
    } else if (strncmp(mangled, "$s", 2) == 0) {
        p += 2;
        dollarS = 1;
    } else {
        return 0;
    }
    char module[256], first[256], second[256];
    if (!SBParseMangledLabel(&p, end, module, sizeof(module))) {
        return 0;
    }
    if (!SBParseMangledLabel(&p, end, first, sizeof(first))) {
        return 0;
    }
    if (nested) {
        if (!SBParseMangledLabel(&p, end, second, sizeof(second))) {
            return 0;
        }
        if (p != end) {
            return 0;
        }
        if (snprintf(out, outSize, "%s.%s.%s", module, first, second) >= (int)outSize) {
            return 0;
        }
    } else {
        if (dollarS) {
            if (p + 1 != end || *p != 'C') {
                return 0;
            }
        } else if (p != end) {
            return 0;
        }
        if (snprintf(out, outSize, "%s.%s", module, first) >= (int)outSize) {
            return 0;
        }
    }
    return 1;
}

/// 逐项 corrupt 种类（0.2.43 分项统计用；SBClassROName 经 *corruptKindOut 回传）。
typedef enum {
    SB_CORRUPT_NONE = 0,
    SB_CORRUPT_RW_PATH,         // RW 分支读 rw_t／ro_or_rw_ext 失败
    SB_CORRUPT_RO_RANGE,        // ro 越界或堆 ro 副本结构校验失败
    SB_CORRUPT_NAME_RANGE,      // 名指针越界
    SB_CORRUPT_BITS_UNREADABLE  // 类对象头（bits 槽）不可读
} SBClassCorruptKind;

/// 堆 ro 副本结构校验（0.2.43 根因 B2）：实现化后 make_ro_writeable 会把
/// ro 复制到堆上（RW_COPIED_RO），此时 ro 不在镜像内。8 字节对齐、≥4096，
/// 且 ro 头三字段（flags／instanceStart／instanceSize）合理
/// （instanceSize < 1MB，instanceStart <= instanceSize）才接受为真 ro；
/// 校验不过即 corrupt。名指针仍须落在镜像内（下一条判定覆盖）。
static int SBHeapROStructValid(uintptr_t ro) {
    if (ro < 4096 || (ro & 7U) != 0) {
        return 0;
    }
    uint32_t flags = *(const uint32_t *)(ro + 0);
    uint32_t instanceStart = *(const uint32_t *)(ro + 4);
    uint32_t instanceSize = *(const uint32_t *)(ro + 8);
    (void)flags; // 只验可读，不验取值
    if (instanceSize >= 1024 * 1024) {
        return 0;
    }
    if (instanceStart > instanceSize) {
        return 0;
    }
    return 1;
}

/// 取一个类对象的 ro 名。返回名指针（借用镜像内存，不持有），或 NULL。
/// *isLazyOut 置 1 表示 ro->name 为空（lazily named，读表无法匹配）；
/// *isCorruptOut 置 1 表示指针越界／结构损坏（跳过该项）；
/// *corruptKindOut 回传 corrupt 种类（分项统计用，可空）。
/// lo/hi：镜像地址区间（ro 与 name 必须落在内；rw_t 在堆上，另验标志；
/// 堆上的 ro 副本经 SBHeapROStructValid 校验后接受）。
static const char *SBClassROName(uintptr_t cls, uintptr_t lo, uintptr_t hi,
                                 int *isLazyOut, int *isCorruptOut,
                                 int *corruptKindOut) {
    if (isLazyOut) *isLazyOut = 0;
    if (isCorruptOut) *isCorruptOut = 0;
    if (corruptKindOut) *corruptKindOut = SB_CORRUPT_NONE;
    if (!SBPtrInRange(cls, lo, hi) || cls + 40 < cls) {
        if (isCorruptOut) *isCorruptOut = 1;
        if (corruptKindOut) *corruptKindOut = SB_CORRUPT_BITS_UNREADABLE;
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
            if (corruptKindOut) *corruptKindOut = SB_CORRUPT_RW_PATH;
            return NULL;
        }
        // 0.2.43（根因 B1）：删掉 RW_REALIZED 未置位时的回退分支——bits 已置
        // RW 位即指向堆上 class_rw_t，与 RW_REALIZED 无关（objc4 data()->ro()
        // 同款：ro_or_rw_ext 在 setData 之前已有效）；旧回退把 bits 当 ro
        // 指针剥签＋掩码，得到堆地址后必被区间判定杀死，恒错。
        // rwFlags 只读不分支（留作诊断）。
        uint32_t rwFlags = *(const uint32_t *)data;
        (void)rwFlags;
        // ro_or_rw_ext 在 rw_t +8（flags 4 + witness 2 + index 2）。
        uintptr_t v = *(const uintptr_t *)(data + 8);
        if (v & 1U) {
            // rw_ext：首字段即 ro（PointerUnion T2，低位 1）。
            uintptr_t rwe = SB_STRIP_RO_PTR(v & ~1UL);
            if (rwe < 4096 || (rwe & 7U) != 0) {
                if (isCorruptOut) *isCorruptOut = 1;
                if (corruptKindOut) *corruptKindOut = SB_CORRUPT_RW_PATH;
                return NULL;
            }
            ro = SB_STRIP_RO_PTR(*(const uintptr_t *)rwe);
        } else {
            ro = SB_STRIP_RO_PTR(v);
        }
    } else {
        // 未实现化：bits 即 on-disk ro 指针（剥签 RO 键再掩码）。
        ro = SB_STRIP_RO_PTR(bits) & SB_FAST_DATA_MASK;
    }
    if (ro == 0) {
        if (isCorruptOut) *isCorruptOut = 1;
        if (corruptKindOut) *corruptKindOut = SB_CORRUPT_RO_RANGE;
        return NULL;
    }
    if (!SBPtrInRange(ro, lo, hi)) {
        // 0.2.43（根因 B2）：ro 不在镜像内不再直接判死——先结构校验
        // （堆 ro 副本），校验不过才计 corrupt。
        if (!SBHeapROStructValid(ro)) {
            if (isCorruptOut) *isCorruptOut = 1;
            if (corruptKindOut) *corruptKindOut = SB_CORRUPT_RO_RANGE;
            return NULL;
        }
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
        if (corruptKindOut) *corruptKindOut = SB_CORRUPT_NAME_RANGE;
        return NULL;
    }
    return name;
}

/// 扫一张类表（__objc_classlist 或 __objc_nlclslist）：逐项读 ro 名比对，
/// 原名或反混淆名任一等于 wanted 即命中，返回该类指针；扫完无匹配返回 NULL。
/// stats 可空；传了则累加（扫过的项数、空名项、越界项及其分项）。
static void *SBScanClassListEntries(const uintptr_t *entries, uint64_t entryCount,
                                    uintptr_t lo, uintptr_t hi,
                                    const char *wantedName,
                                    SBGuestMachOClassScanStats *stats) {
    for (uint64_t i = 0; i < entryCount; i++) {
        uintptr_t cls = entries[i];
        if (stats) {
            stats->classesScanned++;
        }
        if (cls == 0 || !SBPtrInRange(cls, lo, hi)) {
            if (stats) {
                stats->corruptCount++;
                stats->corruptClsRange++;
            }
            continue;
        }
        int isLazy = 0, isCorrupt = 0, corruptKind = SB_CORRUPT_NONE;
        const char *name = SBClassROName(cls, lo, hi, &isLazy, &isCorrupt, &corruptKind);
        if (isLazy) {
            if (stats) {
                stats->nullNameCount++;
            }
            continue;
        }
        if (isCorrupt || !name) {
            if (stats) {
                stats->corruptCount++;
                switch (corruptKind) {
                    case SB_CORRUPT_RW_PATH:
                        stats->corruptRwPath++;
                        break;
                    case SB_CORRUPT_RO_RANGE:
                        stats->corruptRoRange++;
                        break;
                    case SB_CORRUPT_NAME_RANGE:
                        stats->corruptNameRange++;
                        break;
                    case SB_CORRUPT_BITS_UNREADABLE:
                        stats->corruptBitsUnreadable++;
                        break;
                    default:
                        break;
                }
            }
            continue;
        }
        if (SBBoundedNameEquals(name, lo, hi, wantedName)) {
            return (void *)cls;
        }
        // 0.2.43（根因 A）：盘上 Swift 混淆名再反混淆比对一次（须先验名串
        // 在区间内有 NUL 结尾，不让 strlen 读出界）。
        size_t nameLen = 0;
        if (SBNameLengthInRange(name, lo, hi, &nameLen)) {
            char demangled[512];
            if (SBSwiftDemangleClassName(name, demangled, sizeof(demangled)) &&
                strcmp(demangled, wantedName) == 0) {
                return (void *)cls;
            }
        }
    }
    return NULL;
}

void *SBGuestMachOClassScanImage(const void *imageBase, long slide,
                                 const char *wantedName,
                                 SBGuestMachOClassScanStats *stats) {
    if (stats) {
        stats->classesScanned = 0;
        stats->nullNameCount = 0;
        stats->corruptCount = 0;
        stats->foundClassList = 0;
        stats->corruptClsRange = 0;
        stats->corruptRwPath = 0;
        stats->corruptRoRange = 0;
        stats->corruptNameRange = 0;
        stats->corruptBitsUnreadable = 0;
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
    uintptr_t nlListAddr = 0;
    uint64_t nlListSize = 0;
    int foundNlList = 0;
    // 走一遍 LC_SEGMENT_64：算镜像地址区间，找 __objc_classlist 段
    //（段名不限——新工具链可能把它放 __DATA_CONST），另找
    // __objc_nlclslist（非懒类子集；现代 App 里它是 classlist 的子集，
    // 只有 arclite hack 的旧二进制才有仅在 nlclslist 的类——补扫是廉价
    // 的完备性修正，见调查报告假说 (iv)）。
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
                } else if (strncmp(sect->sectname, "__objc_nlclslist", 16) == 0) {
                    nlListAddr = (uintptr_t)(sect->addr + (uint64_t)slide);
                    nlListSize = sect->size;
                    foundNlList = 1;
                }
                sectCursor += sizeof(SBSection64);
            }
        }
        cursor += lc->cmdsize;
    }
    if (!foundList && !foundNlList) {
        return NULL;
    }
    if (stats) {
        // 任一表存在即算有类表（0.2.43：foundClassList 语义改为任一表存在）。
        stats->foundClassList = 1;
    }
    // 先扫 __objc_classlist（主表），再扫 __objc_nlclslist（补集）；
    // 主表命中即返回。主表结构损坏（地址／条数越界）仍整镜像失败，
    // 与 0.2.42 语义一致；nl 表结构损坏只跳过该表，不牵连主表。
    if (foundList) {
        if (listAddr == 0 || listSize == 0) {
            return NULL;
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
        void *found = SBScanClassListEntries((const uintptr_t *)listAddr,
                                             entryCount, lo, hi, wantedName, stats);
        if (found) {
            return found;
        }
    }
    if (foundNlList && nlListAddr != 0 && nlListSize != 0) {
        uint64_t nlEntryCount = nlListSize / sizeof(uintptr_t);
        if (nlEntryCount > 0 && nlEntryCount <= SB_MAX_CLASSLIST_ENTRIES &&
            SBPtrInRange(nlListAddr, lo, hi) &&
            nlListAddr + nlEntryCount * sizeof(uintptr_t) >= nlListAddr &&
            nlListAddr + nlEntryCount * sizeof(uintptr_t) <= hi) {
            void *found = SBScanClassListEntries((const uintptr_t *)nlListAddr,
                                                 nlEntryCount, lo, hi, wantedName, stats);
            if (found) {
                return found;
            }
        }
    }
    return NULL;
}

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#include <unistd.h>

static char g_classListFailureReason[512];

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
/// 入参 imageReal 须已是 realpath 解析后的路径（调用方一次调用内只
/// 解析一次，见 SBGuestMachOClassNamedInGuest 的缓存；0.2.42 每镜像
/// 重复 realpath 是每次探测 ~400ms 的主因，见调查报告缺陷 D）。
static int SBGuestImageIsInGuest(const char *imageReal, const char *guestExecReal,
                                 const char *guestAppReal) {
    if (!imageReal || imageReal[0] == '\0') {
        return 0;
    }
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
    SBGuestMachOClassScanStats total = {0};
    int anyGuestImage = 0;
    int anyClassList = 0;
    uint32_t imageCount = _dyld_image_count();
    // 0.2.43（缺陷 D）：realpath 缓存——镜像路径在进程内不变，一次调用内
    // 每个镜像只解析一次（原实现每镜像每遍各调多次，~1400 镜像约 400ms；
    // 两遍扫描共用同一份缓存，探测应降到毫秒级）。
    char (*resolvedPaths)[PATH_MAX] = NULL;
    if (imageCount > 0) {
        resolvedPaths = (char (*)[PATH_MAX])calloc(imageCount, sizeof(*resolvedPaths));
    }
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (!imageName || !resolvedPaths) {
            continue;
        }
        SBGuestRealPath(imageName, resolvedPaths[i], PATH_MAX);
    }
    // 两遍：先扫主可执行镜像（精确匹配），再扫包内其他镜像（framework）。
    // 主镜像优先——同名类分属主镜像与 framework 时，取主镜像的。
    for (int pass = 0; pass < 2; pass++) {
        for (uint32_t i = 0; i < imageCount; i++) {
            const char *imageName = _dyld_get_image_name(i);
            if (!imageName) {
                continue;
            }
            const char *imageReal = resolvedPaths ? resolvedPaths[i] : imageName;
            int isExec = (execReal[0] != '\0' && strcmp(imageReal, execReal) == 0);
            if (pass == 0 && !isExec) {
                continue;
            }
            if (pass == 1 && (isExec || !SBGuestImageIsInGuest(imageReal, execReal, appReal))) {
                continue;
            }
            if (pass == 0 && !SBGuestImageIsInGuest(imageReal, execReal, appReal)) {
                continue;
            }
            const struct mach_header *header = _dyld_get_image_header(i);
            if (!header) {
                continue;
            }
            anyGuestImage = 1;
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            SBGuestMachOClassScanStats stats = {0};
            void *found = SBGuestMachOClassScanImage(header, (long)slide,
                                                     className, &stats);
            total.classesScanned += stats.classesScanned;
            total.nullNameCount += stats.nullNameCount;
            total.corruptCount += stats.corruptCount;
            total.corruptClsRange += stats.corruptClsRange;
            total.corruptRwPath += stats.corruptRwPath;
            total.corruptRoRange += stats.corruptRoRange;
            total.corruptNameRange += stats.corruptNameRange;
            total.corruptBitsUnreadable += stats.corruptBitsUnreadable;
            if (stats.foundClassList) {
                anyClassList = 1;
            }
            if (found) {
                free(resolvedPaths);
                return found;
            }
        }
    }
    free(resolvedPaths);
    // 未命中：区分“单纯查无此类”与“读表本身失败”，只许后者写原因串。
    // 0.2.43（缺陷 C）：原因串只陈述扫描事实——扫了多少项、分项坏了多少、
    // 多少名为空；坏项只被跳过，从不导致未命中，故永不再写
    // “因 N 个坏项而未命中”（0.2.42 的写法是错误归因）。
    const char *reason = NULL;
    if (!anyGuestImage) {
        reason = "客镜像未在 dyld 列表里（dlopen 后应已加载）";
    } else if (!anyClassList) {
        reason = "客镜像无 __objc_classlist 段（非常规 Mach-O 布局）";
    } else if (total.corruptCount > 0 || total.nullNameCount > 0) {
        (void)snprintf(g_classListFailureReason, sizeof(g_classListFailureReason),
                       "未命中（扫 %u 项：越界／损坏 %u 项＝类指针 %u／ro 区间 %u／名指针 %u／RW 路径 %u／类头 %u，名为空 %u 项）",
                       total.classesScanned, total.corruptCount,
                       total.corruptClsRange, total.corruptRoRange,
                       total.corruptNameRange, total.corruptRwPath,
                       total.corruptBitsUnreadable, total.nullNameCount);
        reason = g_classListFailureReason;
    }
    if (reason && failureReasonOut) {
        *failureReasonOut = reason;
    }
    return NULL;
}
#endif
