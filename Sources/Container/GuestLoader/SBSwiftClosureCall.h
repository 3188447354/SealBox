// SBSwiftClosureCall.h — 经 Mirror 发现的 Swift 闭包 () -> T 的 C 层调用（0.2.34）。
//
// 为什么必须走 C 层：Swift 里 `child.value as? () -> Any` 对具体返回类型
// 的闭包强转失败（函数类型强转要求精确匹配，无协变），且 Mirror 在闭包值上
// 不显示子项——Swift 侧无法调用一个类型未知的闭包。C 层从 Any 存在容器里读出
// 闭包的 (函数指针, 上下文) 与函数类型元数据，按 Swift ABI 判定返回约定后
// 用 swiftcall 调它，再把结果包回 Any。
//
// 调用约定核定（源码实证，见 build log 0.2.34 节；Husk 2.0 实际闭包的
// 返回约定另由反汇编核定，两者须一致）：
//  - 函数类型元数据（kind=0x302）：Kind@0（8 字节）、Flags@8（size_t，
//    Convention 在 bits 16–23：Swift=0、Block=1、Thin=2、C=3；
//    NumParameters 在 bits 0–15；Throws 0x01000000；Async 0x20000000；
//    Extended 0x80000000）、ResultType@16（直接字段，非 trailing）。
//  - 结果类型元数据前一字 metadata[-1] 是 ValueWitnesses 指针（FullMetadata
//    头两字：layoutString@-2、ValueWitnesses@-1）；表内 8 个函数指针后
//    size@64、stride@72、flags@80（uint32，alignment＝低字节＋1；
//    IsNonInline=0x00020000、IsNonBitwiseTakable=0x00100000、
//    Incomplete=0x00400000）、extraInhabitantCount@84。
//  - 直接返回当且仅当结果的标量展开 ≤4 个寄存器（Clang SwiftABIInfo::
//    shouldPassIndirectly → occupiesMoreThan(..., 4)；AArch64 不覆写）；
//    间接返回时 sret 指针在 x8（AAPCS），上下文（swiftself）在 x20。
//  - 不调任何 value witness 函数：直接/间接两路都只在 bitwise-takable
//    类型上用 memcpy 搬运（take 的定义就是 bitwise copy）；witness 函数
//    指针是 ptrauth 签名的，C 层裸调会崩，故一律不用。
//  - 判定不出时干净拒绝（返回 NO），绝不猜任一方向：size>4096、
//    alignment>16 的大结果、IsNonInline 且 size 25–32、IsNonInline 且非
//    bitwise-takable、alignment>8 的非内联小结果、以及下述已知边界。
//
// 已知边界（见 build log 0.2.34 节）：直接路要求结果 loadable 且 size≤24，
// 但标量展开的寄存器数还取决于字段构成——一个 ≤24 字节的 struct 若含 ≥5 个
// 浮点/向量标量字段（如 5 个 Float），展开超 4 寄存器、编译器会改间接返回，
// 而本函数只看 size/flags 会误判为直接。SwiftUI View 结构体的存储属性
// 实际是引用/包装（指针）为主；Husk 的实际闭包已由反汇编核定（见 build
// log），其它客若命中该形状会在真机日志里表现为结果错乱——届时按字段记录
// 补寄存器计数，不在此版臆测修法。
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
