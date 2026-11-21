// SBSwiftClosureCall.h — 经 Mirror 发现的 Swift 闭包 () -> T 的 C 层调用（0.2.34）。
//
// 为什么必须走 C 层：Swift 里 `child.value as? () -> Any` 对具体返回类型
// 的闭包强转失败（函数类型强转要求精确匹配，无协变），且 Mirror 在闭包值上
// 不显示子项——Swift 侧无法调用一个类型未知的闭包。C 层从 Any 存在容器里读出
// 闭包的 (函数指针, 上下文) 与函数类型元数据，按 Swift ABI 判定返回约定后
// 用 swiftcall 调它，再把结果包回 Any。
//
// 调用约定核定（源码实证，见 build log 0.2.34 节；Husk 2.0 实际闭包的
// 返回约定另由反汇编核定，两者须一致；0.2.36 改判：见下）：
//  - 函数类型元数据（kind=0x302）：Kind@0（8 字节）、Flags@8（size_t，
//    Convention 在 bits 16–23：Swift=0、Block=1、Thin=2、C=3；
//    NumParameters 在 bits 0–15；Throws 0x01000000；Async 0x20000000；
//    Extended 0x80000000）、ResultType@16（直接字段，非 trailing）。
//  - 结果类型元数据前一字 metadata[-1] 是 ValueWitnesses 指针（FullMetadata
//    头两字：layoutString@-2、ValueWitnesses@-1）；表内 8 个函数指针后
//    size@64、stride@72、flags@80（uint32，alignment＝低字节＋1；
//    IsNonInline=0x00020000、IsNonBitwiseTakable=0x00100000、
//    Incomplete=0x00400000）、extraInhabitantCount@84。
//  - 一律间接返回（0.2.36 定论，取代 0.2.34/0.2.35 的 size/flags 选路）：
//    本函数唯一调用方是 findRootView，闭包一律取自 SwiftUI 视图结构体的
//    泛型字段（如 WindowGroup<Content> 的 () -> Content），该函数值按抽象
//    签名编译，结果一律走 sret（x8），与尺寸/flags 无关。实证：Asspp 4.2.1
//    的 content.lazy 闭包（文件偏移 0x5B44）入口 `mov x19, x8`、返回前把
//    9 字节结果写进 *x8；其 size=9 flags=0x10007 在 0.2.35 判定下走直接路
//    即死因（见 build log 0.2.36 节与 tmp-sb0236verify/verify_0236_closure.py）。
//    VWT flags 只决定结果能不能 memcpy 搬运，不决定调用约定。
//  - 不调任何 value witness 函数：只在 bitwise-takable 类型上用 memcpy
//    搬运（take 的定义就是 bitwise copy）；witness 函数指针是 ptrauth
//    签名的，C 层裸调会崩，故一律不用。
//  - 拒绝只留给真正搬不出的情形：非 bitwise-takable、alignment>16、
//    size>4096；拒绝行须写清判定依据（size/align/flags）。
//  - 0.2.37：捕获型闭包（Swift 约定且 ctx 非空）一律拒绝——体内部可能读
//    SwiftUI 图状态（StateObject/LazyState/environmentStores），图外直调
//    即陷阱；能用的 Husk/Asspp 的 ctx 都是 0x0，Locus 的 ctx 非空即死因。
//    Thin 闭包无上下文，不受此限。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 调用一个经 Mirror 发现的 Swift 闭包值（() -> T）。
///
/// closureAny：指向一个 Any 存在容器（32 字节：24 字节值缓冲＋8 字节类型
/// 元数据），其中存的是闭包值（函数指针＋上下文，16 字节）。
/// outAny：指向一个 32 字节缓冲，成功时填成结果的 Any 存在容器
/// （值缓冲＋结果类型元数据）；失败时不动。
/// errorOut：失败原因（C 串，调用方传缓冲；可为 NULL，errorOutLen 为 0 时
/// 不写）。成功时不动。
/// 返回 YES＝已调且 outAny 已填；NO＝干净拒绝（未调闭包，outAny 不动）。
/// 每一步都记诊断日志（SBDiagLogLine），失败原因同时进 errorOut。
BOOL SBCallSwiftClosure(const void *closureAny, void *outAny,
                        char * _Nullable errorOut, size_t errorOutLen);

NS_ASSUME_NONNULL_END
