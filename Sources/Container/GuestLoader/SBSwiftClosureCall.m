// SBSwiftClosureCall.m — 经 Mirror 发现的 Swift 闭包 () -> T 的 C 层调用（0.2.34）。
//
// 证据链见 SBSwiftClosureCall.h 头注释与 build log 0.2.34 节。
// 要点重述：
//  - Any 存在容器 32 字节：值缓冲 0–23，类型元数据 24–31。
//  - 闭包值（thick 函数值）16 字节：函数指针在 +0，上下文在 +8
//    （Husk 2.0 反汇编已核定：WindowGroup init 两处调用点与嵌套闭包
//    onOpenURL 调用点一致，fn 在先寄存器、ctx 在后；见 build log 0.2.34 节 (a1)）。
//  - 函数类型元数据 kind=0x302：Kind@0、Flags@8、ResultType@16。
//  - 结果类型元数据 metadata[-1] 是 ValueWitnesses 指针；
//    size@64、stride@72、flags@80（uint32）。
//  - 直接路：loadable 结果展开 ≤4 寄存器（Clang SwiftABIInfo::shouldPassIndirectly
//    → occupiesMoreThan(..., 4)），返回 4×uintptr_t 结构体，值在 x0–x3；
//    Any 值缓冲只有 24 字节：size≤24 且 align≤8 才 inline，否则装盒
//    （0.2.35 修：直接 memcpy 再写 out[3] 会吃掉值字节 24–31）。
//  - 间接路：IsNonInline（address-only）置位即间接，与 size 无关；或 loadable
//    但 size>32（装不进 4 个寄存器），返回一个 4096 字节、16 字节对齐的
//    结构体，Clang 降为 sret，指针在 x8。
//  - 不调任何 value witness 函数（witness 指针带 ptrauth 签名，C 层裸调会崩）。
//    搬运只用 memcpy：take 的定义就是 bitwise copy，适用于 bitwise-takable
//    类型；非 bitwise-takable 的结果一律干净拒绝。
//    生命周期：callee 交出 +1 的值，memcpy 进盒即一次 take；源槽是栈内存，
//    永不析构，不多 retain、不调 destroy，盒销毁时 Swift 释放一次。
//  - swift_allocBox 是 libswiftCore 导出的 swiftcall 函数，返回
//    BoxPair＝{object, buffer}；间接路与直接装盒路共用。
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

// ---- swiftcall 调用桩（Clang 按 Swift 聚合降低展开）----
// 直接路：4×uintptr_t＝4 个 int 寄存器，≤4 → 直接返回，值在 x0–x3。
typedef struct { uintptr_t w0, w1, w2, w3; } SBClosureRet4;
typedef SBClosureRet4 (__attribute__((swiftcall)) *SBClosureDirectFn)(
    void *ctx __attribute__((swiftself)));
// 间接路：4096 字节结构体＝512 个 int 寄存器，>4 → 间接返回，sret 指针走 x8，
// 上下文仍走 x20（swiftself）。调用方在栈上开 4096 字节、16 字节对齐的缓冲，
// callee 写 size（≤4096）字节进去，余下字节忽略。4096 覆盖 Husk 的 216 字节
// 及一般 ContentView；超 4096 的结果干净拒绝（见判定）。
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

    // 3. 结果类型判定。
    const uintptr_t *rmd = (const uintptr_t *)resultMD;
    uintptr_t rkind = rmd[0];
    SBDiagLogLine([[NSString stringWithFormat:@"Swift 闭包调用：结果 kind=0x%lx", (unsigned long)rkind] UTF8String]);

    // 3a. 类结果（Class/ObjCClassWrapper/ForeignClass）：单指针，直接返回。
    if (rkind == SB_MD_KIND_CLASS || rkind == SB_MD_KIND_OBJC_CLASS_WRAPPER ||
        rkind == SB_MD_KIND_FOREIGN_CLASS) {
        SBClosureRet4 ret = ((SBClosureDirectFn)fn)(callCtx);
        uintptr_t *out = (uintptr_t *)outAny;
        out[0] = ret.w0;
        out[1] = 0;
        out[2] = 0;
        out[3] = (uintptr_t)resultMD;
        SBDiagLogLine([[NSString stringWithFormat:@"Swift 闭包调用：类结果，直接返回，对象=%p", (void *)ret.w0] UTF8String]);
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

    // 3d. 间接返回判定（0.2.35 重写；判定表原型见 tmp-sb0235verify/verify_0235.py）。
    //  (i) IsNonInline 置位 ⇒ address-only：值须 out-of-line 存储
    //  （MetadataValues.h：isInlineStorage() "True if the type requires
    //  out-of-line allocation of its storage"），调用方传/收一律间接，
    //  与 size 无关。0.2.34 的 size≤24 附加条件是错的：真机 Husk 闭包
    //  的运行时包装壳 size=32、flags=0x30007 因此被拒（code 1004）。
    //  (ii) 未置位但 size>32 ⇒ loadable 且装不进 4 个寄存器，一定间接
    //  （Husk 闭包静态返回 216 字节即此路；反汇编已证入口存 x8）。
    //  0.2.34 的教训：本函数曾有一处早期拒绝（size>32 直接拒），它先于
    //  3d 触发，使 3d 的 size>32 间接分支成死代码——0.2.34 报告称“已改
    //  间接”但残留未删，216 字节结果仍会被拒；0.2.35 已删该早期拒绝。
    //  两路共用一个大 sret 缓冲（4096 字节栈空间，16 字节对齐），callee
    //  写 rsize 字节，再 swift_allocBox 建盒、memcpy 搬入
    //  （bitwise-takable 类型 take 即 memcpy，不调 witness 函数）。
    //  生命周期：callee 交出的是 +1 的值（sret 槽 / 寄存器里），memcpy
    //  搬入盒即一次 take——源槽是栈内存，永不析构，不多 retain、不调
    //  destroy；盒销毁时 Swift 按值 witness 释放一次，不多不少。
    //  拒绝只留给真正判不出的情形（非 bitwise-takable、对齐>16、size>4096），
    //  且拒绝行须写清判定依据（size/align/flags）。
    BOOL indirect = NO;
    if (rflags & SB_VW_NON_INLINE) {
        if (rflags & SB_VW_NON_BITWISE_TAKABLE) {
            return SBFail(errorOut, errorOutLen, "结果 address-only 且非 bitwise-takable，无法搬运，拒绝");
        }
        if (ralign > 16) {
            char buf[192];
            snprintf(buf, sizeof(buf), "结果 address-only 且对齐 %zu，超 sret 缓冲对齐（16），拒绝",
                     ralign);
            return SBFail(errorOut, errorOutLen, buf);
        }
        if (rsize > 4096) {
            char buf[160];
            snprintf(buf, sizeof(buf), "结果 %zu 字节，超 sret 缓冲 4096，拒绝", rsize);
            return SBFail(errorOut, errorOutLen, buf);
        }
        indirect = YES;
    } else if (rsize > 32) {
        if (rflags & SB_VW_NON_BITWISE_TAKABLE) {
            return SBFail(errorOut, errorOutLen, "结果 >32 字节且非 bitwise-takable，无法搬运，拒绝");
        }
        if (ralign > 16) {
            char buf[192];
            snprintf(buf, sizeof(buf), "结果 %zu 字节且对齐 %zu，超 sret 缓冲对齐（16），拒绝",
                     rsize, ralign);
            return SBFail(errorOut, errorOutLen, buf);
        }
        if (rsize > 4096) {
            char buf[160];
            snprintf(buf, sizeof(buf), "结果 %zu 字节，超 sret 缓冲 4096，拒绝", rsize);
            return SBFail(errorOut, errorOutLen, buf);
        }
        indirect = YES;
    }
    if (indirect) {
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

    // 3e. 直接路：loadable（IsNonInline 未置位），返回值在 x0–x3。
    // Any 值缓冲只有 24 字节（NumWords_ValueBuffer=3）：size≤24 且 align≤8
    // 才 inline；25–32 字节或 align>8 须装盒——直接 memcpy 再写 out[3]
    // 会吃掉值字节 24–31（0.2.35 修，原型见 tmp-sb0235verify/verify_0235.py）。
    // 已知边界：≤24 字节 struct 含 ≥5 个浮点/向量标量字段时展开超 4 寄存器、
    // 实为间接返回，本路会误判（见头注释）；SwiftUI View 结构体以指针为主。
    {
        SBClosureRet4 ret = ((SBClosureDirectFn)fn)(callCtx);
        uintptr_t *out = (uintptr_t *)outAny;
        if (rsize <= 24 && ralign <= 8) {
            out[0] = 0;
            out[1] = 0;
            out[2] = 0;
            memcpy(out, &ret, rsize);
            out[3] = (uintptr_t)resultMD;
            SBDiagLogLine([[NSString stringWithFormat:@"Swift 闭包调用：直接返回，size=%zu 已填 Any", rsize] UTF8String]);
        } else {
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
            out[0] = (uintptr_t)box.object;
            out[1] = 0;
            out[2] = 0;
            out[3] = (uintptr_t)resultMD;
            SBDiagLogLine([[NSString stringWithFormat:@"Swift 闭包调用：直接返回，size=%zu 已装盒", rsize] UTF8String]);
        }
        return YES;
    }
}
