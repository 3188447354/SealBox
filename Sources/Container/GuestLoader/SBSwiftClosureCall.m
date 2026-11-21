// SBSwiftClosureCall.m — 经 Mirror 发现的 Swift 闭包 () -> T 的 C 层调用（0.2.34）。
//
// 证据链见 SBSwiftClosureCall.h 头注释与 build log 0.2.34/0.2.35/0.2.36 节。
// 要点重述：
//  - Any 存在容器 32 字节：值缓冲 0–23，类型元数据 24–31。
//  - 闭包值（thick 函数值）16 字节：函数指针在 +0，上下文在 +8
//    （Husk 2.0 反汇编已核定：WindowGroup init 两处调用点与嵌套闭包
//    onOpenURL 调用点一致，fn 在先寄存器、ctx 在后；见 build log 0.2.34 节 (a1)）。
//  - 函数类型元数据 kind=0x302：Kind@0、Flags@8、ResultType@16。
//  - 结果类型元数据 metadata[-1] 是 ValueWitnesses 指针；
//    size@64、stride@72、flags@80（uint32）。
//  - 调用约定（0.2.36 定论，取代 0.2.34/0.2.35 的 size/flags 判定）：
//    本函数唯一调用方是 SBSwiftUIEmbed.findRootView，闭包一律取自 SwiftUI
//    视图结构体的泛型字段（如 WindowGroup<Content> 的 () -> Content）。
//    该函数值按抽象签名编译：泛型上下文里结果布局未知，语义 lowering 把
//    结果定为间接（swiftlang/swift docs/ABI/CallingConvention.rst：
//    “a function intended to be passed as this argument must pass [results]
//    indirectly, even if they are actually known statically to be
//    non-address-only types like Int and Float”），物理 lowering 再把间接
//    结果化作 sret 指针（x8）。因此——与结果尺寸/flags 无关，一律间接。
//    实证：Asspp 4.2.1（与 MJ 已装版五项指纹一致：43,826,800 字节/10700 页、
//    __TEXT 0x10b4000、imports 4443、符号池 192300、entryoff 0x4000）
//    的 content.lazy 闭包（文件偏移 0x5B44，MJ 两回日志 fn 一致）：入口
//    `mov x19, x8` 存 sret，返回前 `str x8, [x19]`＋`strb w9, [x19, #8]`
//    把 9 字节 _ConditionalContent 写进 *x8，x0 不返回值。
//    该结果 size=9 stride=16 flags=0x10007（IsNonPOD 置位、IsNonInline
//    未置位），0.2.35 判定走直接路、x8 是垃圾、callee 经 x8 写内存即陷阱
//    ——0.2.35 真机 Asspp 两回死在闭包调用里即此。VWT flags 只描述结果
//    类型的存储属性（IsNonInline＝address-only 存储），不能决定函数值的
//    调用约定；0.2.34/0.2.35 用 flags/size 选路是把两件事混为一谈。
//    Husk 的 32 字节结果（flags=0x30007）走间接能通，是同一规则的另一面。
//  - 间接路：4096 字节结构体返回值，Clang 降为 sret，指针在 x8，
//    上下文仍走 x20（swiftself）。调用方在栈上开 4096 字节、16 字节对齐的缓冲，
//    callee 写 size（≤4096）字节进去，余下字节忽略。4096 覆盖 Husk 的 216 字节
//    及一般 ContentView；超 4096 的结果干净拒绝（见判定）。
//  - 不调任何 value witness 函数（witness 指针带 ptrauth 签名，C 层裸调会崩）。
//    搬运只用 memcpy：take 的定义就是 bitwise copy，适用于 bitwise-takable
//    类型；非 bitwise-takable 的结果一律干净拒绝。
//    生命周期：callee 交出 +1 的值，memcpy 进盒即一次 take；源槽是栈内存，
//    永不析构，不多 retain、不调 destroy，盒销毁时 Swift 释放一次。
//  - swift_allocBox 是 libswiftCore 导出的 swiftcall 函数，返回
//    BoxPair＝{object, buffer}；值类型结果装盒路共用；类结果不装盒，
//    直接取 sret 缓冲里的对象指针。
#import "SBSwiftClosureCall.h"
#import "SBDiagLog.h"
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>

// ---- Metadata kind（swift/ABI/MetadataKind.def，0.2.32 已核）----
#define SB_MD_KIND_CLASS 0x0
#define SB_MD_KIND_STRUCT 0x200
#define SB_MD_KIND_ENUM 0x201
#define SB_MD_KIND_OPTIONAL 0x202
#define SB_MD_KIND_FOREIGN_CLASS 0x203
#define SB_MD_KIND_TUPLE 0x301
#define SB_MD_KIND_FUNCTION 0x302
#define SB_MD_KIND_OBJC_CLASS_WRAPPER 0x305

// ---- FunctionTypeFlags（swift/ABI/Metadata.h，TargetFunctionTypeFlags）----
#define SB_FN_CONVENTION_MASK 0x00FF0000u
#define SB_FN_CONVENTION_SHIFT 16
#define SB_FN_NUM_PARAMS_MASK 0x0000FFFFu
#define SB_FN_THROWS_MASK 0x01000000u
#define SB_FN_ASYNC_MASK 0x20000000u
#define SB_FN_EXTENDED_MASK 0x80000000u
#define SB_FN_CONV_SWIFT 0
#define SB_FN_CONV_THIN 2

// ---- ValueWitnessFlags（swift/ABI/MetadataValues.h）----
#define SB_VW_ALIGN_MASK 0x000000FFu
#define SB_VW_NON_INLINE 0x00020000u
#define SB_VW_NON_BITWISE_TAKABLE 0x00100000u
#define SB_VW_INCOMPLETE 0x00400000u

// ---- swiftcall 调用桩 ----
// 间接路（唯一调用路，0.2.36）：4096 字节结构体＝512 个 int 寄存器，>4 → 间接返回，sret 指针走 x8，
// 上下文仍走 x20（swiftself）。调用方在栈上开 4096 字节、16 字节对齐的缓冲，
// callee 写 size（≤4096）字节进去，余下字节忽略。4096 覆盖 Husk 的 216 字节
// 及一般 ContentView；超 4096 的结果干净拒绝（见判定）。
// 直接路已删（0.2.36）：泛型字段里取出的闭包一律按抽象签名间接返回，
// 直接路对 Asspp 的 9 字节结果就是死因（见文件头注释）。
typedef struct __attribute__((aligned(16))) { uintptr_t w[512]; } SBClosureRetHuge;
typedef SBClosureRetHuge (__attribute__((swiftcall)) *SBClosureIndirectHugeFn)(
    void *ctx __attribute__((swiftself)));
// 空结果路：() -> Void，什么都不返回。
typedef void (__attribute__((swiftcall)) *SBClosureVoidFn)(
    void *ctx __attribute__((swiftself)));

// swift_allocBox（libswiftCore 导出，swiftcall，返回 BoxPair＝{object, buffer}）。
typedef struct { void *object; void *buffer; } SBBoxPair;
typedef SBBoxPair (__attribute__((swiftcall)) *SBAllocBoxFn)(const void *type);

static void SBSetError(char *errorOut, size_t errorOutLen, const char *msg) {
    if (errorOut != NULL && errorOutLen > 0) {
        snprintf(errorOut, errorOutLen, "%s", msg);
    }
}

static BOOL SBFail(char *errorOut, size_t errorOutLen, const char *msg) {
    // 0.2.35：msg 是 UTF-8 的 C 串，绝不能走 stringWithFormat 的 %s——%s 按
    // 默认 C 串编码（此处实为 MacRoman）解码字节再 UTF-8 重编码，中文全变
    // 乱码（0.2.34 真机日志 90/172 行已证：预期串 UTF-8 字节逐字节按
    // MacRoman 解码再 UTF-8 编码，即得日志所见乱码；格式串自身的中文完好，
    // 只坏 %s 代入部分）。先 stringWithUTF8String: 转 NSString，再用 %@。
    NSString *msgStr = (msg != NULL) ? [NSString stringWithUTF8String:msg] : nil;
    if (msgStr == nil) {
        msgStr = @"（错误信息无法解码为 UTF-8）";
    }
    SBDiagLogLine([[NSString stringWithFormat:@"Swift 闭包调用：拒绝：%@", msgStr] UTF8String]);
    SBSetError(errorOut, errorOutLen, msg);
    return NO;
}

static SBAllocBoxFn SBGetAllocBox(void) {
    static SBAllocBoxFn fn = NULL;
    static int tried = 0;
    if (!tried) {
        tried = 1;
        fn = (SBAllocBoxFn)dlsym(RTLD_DEFAULT, "swift_allocBox");
    }
    return fn;
}

BOOL SBCallSwiftClosure(const void *closureAny, void *outAny,
                        char *errorOut, size_t errorOutLen) {
    if (closureAny == NULL || outAny == NULL) {
        return SBFail(errorOut, errorOutLen, "空指针入参");
    }
    // 1. 从 Any 存在容器读闭包值：fn 在 +0，ctx 在 +8，函数类型元数据在 +24。
    const uintptr_t *words = (const uintptr_t *)closureAny;
    void *fn = (void *)words[0];
    void *ctx = (void *)words[1];
    const void *fnTypeMD = (const void *)words[3];
    SBDiagLogLine([[NSString stringWithFormat:@"Swift 闭包调用：fn=%p ctx=%p fnTypeMD=%p", fn, ctx, fnTypeMD] UTF8String]);
    if (fn == NULL || fnTypeMD == NULL) {
        return SBFail(errorOut, errorOutLen, "闭包值为空（函数指针/类型元数据为空）");
    }

    // 2. 函数类型元数据校验：kind=0x302、0 参数、Swift 或 Thin 约定、非抛错、非 async。
    const uintptr_t *md = (const uintptr_t *)fnTypeMD;
    uintptr_t fnKind = md[0];
    if (fnKind != SB_MD_KIND_FUNCTION) {
        char buf[128];
        snprintf(buf, sizeof(buf), "闭包类型不是函数类型（kind=0x%lx）",
                 (unsigned long)fnKind);
        return SBFail(errorOut, errorOutLen, buf);
    }
    size_t fnFlags = (size_t)md[1];
    unsigned conv = (unsigned)((fnFlags & SB_FN_CONVENTION_MASK) >> SB_FN_CONVENTION_SHIFT);
    unsigned numParams = (unsigned)(fnFlags & SB_FN_NUM_PARAMS_MASK);
    const void *resultMD = (const void *)md[2];
    SBDiagLogLine([[NSString stringWithFormat:@"Swift 闭包调用：fnFlags=0x%lx convention=%u numParams=%u resultMD=%p",
                                             (unsigned long)fnFlags, conv, numParams, resultMD] UTF8String]);
    if (conv != SB_FN_CONV_SWIFT && conv != SB_FN_CONV_THIN) {
        char buf[128];
        snprintf(buf, sizeof(buf), "闭包不是 Swift/Thin 约定（convention=%u）", conv);
        return SBFail(errorOut, errorOutLen, buf);
    }
    if (numParams != 0) {
        char buf[128];
        snprintf(buf, sizeof(buf), "闭包带参数（numParams=%u），只支持 () -> T", numParams);
        return SBFail(errorOut, errorOutLen, buf);
    }
    if (fnFlags & SB_FN_THROWS_MASK) {
        return SBFail(errorOut, errorOutLen, "闭包可抛错，不支持");
    }
    if (fnFlags & SB_FN_ASYNC_MASK) {
        return SBFail(errorOut, errorOutLen, "闭包是 async，不支持");
    }
    if (fnFlags & SB_FN_EXTENDED_MASK) {
        return SBFail(errorOut, errorOutLen, "闭包带扩展标志，不支持");
    }
    if (resultMD == NULL) {
        return SBFail(errorOut, errorOutLen, "闭包无结果类型");
    }
    // Thin 闭包无上下文；Swift（thick）闭包上下文经 x20（swiftself）。
    void *callCtx = (conv == SB_FN_CONV_SWIFT) ? ctx : NULL;

    // 0.2.37：捕获型闭包拒绝——Locus 反汇编定论（B：死在闭包体内部，不是 C 层传参错）。
    // 闭包体读图依赖访问器（StateObject.wrappedValue / LazyState.wrappedValue /
    // environmentStores）：C 层在 SwiftUI 视图图之外直接调，图状态不存在即陷阱，
    // @try 抓不住。ctx 非空＝闭包捕获了 App 状态（Locus 的 ctx 是 72 字节堆盒子，
    // 含 session/pairing/setupComplete；体一进来就读它们）；能用的 Husk/Asspp
    // 的 ctx 都是 0x0。捕获未必一定 trap（体内部可能不碰图状态），但 C 层无法
    // 预判——宁可干净拒绝，不让进程死在闭包体里。0.2.38 方向：让 SwiftUI 自己
    // 在活的图里求值 body（LiveContainer 路）或先建图上下文；离线无法验证，
    // 不在本版冒险。Thin 闭包无上下文，不受此限。
    if (conv == SB_FN_CONV_SWIFT && ctx != NULL) {
        char buf[192];
        snprintf(buf, sizeof(buf), "闭包捕获了上下文（ctx=%p），体内部可能读 SwiftUI 图状态，直接调用会陷阱，拒绝", ctx);
        return SBFail(errorOut, errorOutLen, buf);
    }

    // 3. 结果类型判定。
    const uintptr_t *rmd = (const uintptr_t *)resultMD;
    uintptr_t rkind = rmd[0];
    SBDiagLogLine([[NSString stringWithFormat:@"Swift 闭包调用：结果 kind=0x%lx", (unsigned long)rkind] UTF8String]);

    // 3a. 类结果（Class/ObjCClassWrapper/ForeignClass）：单指针，同样间接返回。
    // 抽象签名下结果走 sret：callee 把 8 字节对象指针写进 *x8；直接取，不装盒。
    if (rkind == SB_MD_KIND_CLASS || rkind == SB_MD_KIND_OBJC_CLASS_WRAPPER ||
        rkind == SB_MD_KIND_FOREIGN_CLASS) {
        SBClosureRetHuge ret = ((SBClosureIndirectHugeFn)fn)(callCtx);
        uintptr_t *out = (uintptr_t *)outAny;
        out[0] = ret.w[0];
        out[1] = 0;
        out[2] = 0;
        out[3] = (uintptr_t)resultMD;
        SBDiagLogLine([[NSString stringWithFormat:@"Swift 闭包调用：类结果，间接返回，对象=%p", (void *)ret.w[0]] UTF8String]);
        return YES;
    }

    // 3b. 值类型结果：Struct/Enum/Optional/Tuple。读 value witnesses。
    if (rkind != SB_MD_KIND_STRUCT && rkind != SB_MD_KIND_ENUM &&
        rkind != SB_MD_KIND_OPTIONAL && rkind != SB_MD_KIND_TUPLE) {
        char buf[160];
        snprintf(buf, sizeof(buf), "结果类型 kind=0x%lx 不支持（只支持类/Struct/Enum/Optional/Tuple）",
                 (unsigned long)rkind);
        return SBFail(errorOut, errorOutLen, buf);
    }
    // metadata[-1]＝ValueWitnesses 指针（FullMetadata 头）。
    const char *vw = (const char *)rmd[-1];
    if (vw == NULL) {
        return SBFail(errorOut, errorOutLen, "结果类型无 value witnesses");
    }
    size_t rsize = *(const size_t *)(vw + 64);
    size_t rstride = *(const size_t *)(vw + 72);
    uint32_t rflags = *(const uint32_t *)(vw + 80);
    size_t ralign = (size_t)(rflags & SB_VW_ALIGN_MASK) + 1;
    SBDiagLogLine([[NSString stringWithFormat:@"Swift 闭包调用：结果 size=%zu stride=%zu flags=0x%x align=%zu",
                                             rsize, rstride, rflags, ralign] UTF8String]);
    if (rflags & SB_VW_INCOMPLETE) {
        return SBFail(errorOut, errorOutLen, "结果类型元数据未完成");
    }

    // 3c. 空结果（() -> Void）：什么都不返回。
    if (rsize == 0) {
        ((SBClosureVoidFn)fn)(callCtx);
        uintptr_t *out = (uintptr_t *)outAny;
        out[0] = 0;
        out[1] = 0;
        out[2] = 0;
        out[3] = (uintptr_t)resultMD;
        SBDiagLogLine("Swift 闭包调用：空结果，直接返回");
        return YES;
    }

    // 3d. 一律间接返回（0.2.36；判定表原型见 tmp-sb0236verify/verify_0236_closure.py）。
    // 闭包取自泛型字段，按抽象签名编译，结果一律走 sret（x8），与 size/flags
    // 无关——0.2.34/0.2.35 用 IsNonInline/size 选路是错的：Asspp 的 9 字节
    // 结果 flags=0x10007 被判直接，x8 是垃圾、callee 经 x8 写内存即陷阱，
    // 0.2.35 真机两回死在闭包调用里即此。VWT flags 只决定结果能不能 memcpy
    // 搬运，不决定调用约定。sret 缓冲 4096 字节栈空间、16 字节对齐，callee
    // 写 rsize 字节，再 swift_allocBox 建盒、memcpy 搬入（bitwise-takable
    // 类型 take 即 memcpy，不调 witness 函数）。
    // 生命周期：callee 交出的是 +1 的值（sret 槽里），memcpy 搬入盒即一次
    // take——源槽是栈内存，永不析构，不多 retain、不调 destroy；盒销毁时
    // Swift 按值 witness 释放一次，不多不少。
    // 拒绝只留给真正搬不出的情形（非 bitwise-takable、对齐>16、size>4096），
    // 且拒绝行须写清判定依据（size/align/flags）。
    if (rflags & SB_VW_NON_BITWISE_TAKABLE) {
        char buf[192];
        snprintf(buf, sizeof(buf), "结果 size=%zu flags=0x%x 非 bitwise-takable，无法 memcpy 搬运，拒绝",
                 rsize, rflags);
        return SBFail(errorOut, errorOutLen, buf);
    }
    if (ralign > 16) {
        char buf[192];
        snprintf(buf, sizeof(buf), "结果 size=%zu 对齐 %zu，超 sret 缓冲对齐（16），拒绝",
                 rsize, ralign);
        return SBFail(errorOut, errorOutLen, buf);
    }
    if (rsize > 4096) {
        char buf[160];
        snprintf(buf, sizeof(buf), "结果 %zu 字节，超 sret 缓冲 4096，拒绝", rsize);
        return SBFail(errorOut, errorOutLen, buf);
    }
    {
        SBClosureRetHuge ret = ((SBClosureIndirectHugeFn)fn)(callCtx);
        SBAllocBoxFn allocBox = SBGetAllocBox();
        if (allocBox == NULL) {
            return SBFail(errorOut, errorOutLen, "swift_allocBox 未找到");
        }
        SBBoxPair box = allocBox(resultMD);
        if (box.object == NULL || box.buffer == NULL) {
            return SBFail(errorOut, errorOutLen, "swift_allocBox 失败");
        }
        memset(box.buffer, 0, rstride);
        memcpy(box.buffer, &ret, rsize);
        uintptr_t *out = (uintptr_t *)outAny;
        out[0] = (uintptr_t)box.object;
        out[1] = 0;
        out[2] = 0;
        out[3] = (uintptr_t)resultMD;
        SBDiagLogLine([[NSString stringWithFormat:@"Swift 闭包调用：间接返回，size=%zu 已装盒", rsize] UTF8String]);
        return YES;
    }

}
