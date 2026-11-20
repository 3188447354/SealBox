// SBChainedFixupRebind.h — 链式修正感知的 GOT 重绑（0.2.28）。
//
// 在指定镜像里按符号名重绑一个导入符号到替身。两种绑定风格都按名找槽，
// 不依赖槽位当前值：
//   链式修正镜像（LC_DYLD_CHAINED_FIXUPS）：解析 fixup 信息，走链按 import 名
//     找 __got 槽，改写（arm64 无 PAC；arm64e 指针格式返回 NO）。
//   传统懒绑定镜像（LC_DYLD_INFO_ONLY）：按间接符号表按名找
//     __la/__nl_symbol_ptr 槽，直接改写。
//
// 为什么不用 litehook_rebind_symbol：它只改写 S_LAZY_SYMBOL_POINTERS /
// S_NON_LAZY_SYMBOL_POINTERS 段（上游 main commit a7e9f59，litehook.c:1025-1027），
// 链式修正镜像的 __got 是 S_REGULAR，不在内——静默 no-op；且它按槽位当前值
// 比对原函数地址（_litehook_rebind_symbol_in_section），未绑定的懒槽
// （值还是 dyld stub 地址）也改不了。App.main 的重绑须按名找槽，两路都自己做。
#import <Foundation/Foundation.h>
#import <mach-o/loader.h>

NS_ASSUME_NONNULL_BEGIN

/// 在指定镜像里按符号名重绑一个导入符号到替身。
/// 至少改写一个槽返回 YES；符号不在该镜像里、或指针格式不支持（arm64e PAC、
// 32 位、压缩符号池）、或镜像头非法，返回 NO。
/// 只改该镜像的槽，不动其他镜像。
/// 0.2.31：写前校验（链式路）——槽原值须与 dlsym 解析的目标地址一致，
/// 对不上不写、返回 NO（防 0.2.30 Husk 2.0 的写错地址：换算偏一页，钩子
/// 永不触发）；写后回读，不一致也返回 NO。slide 取自 dyld API。
/// execPath：链式修正路须读磁盘文件找原始链项（dlopen 后内存里的槽已被 dyld
/// 写成解析地址，编码被覆盖，走不了链）；传统路不读文件，可传 nil。
BOOL SBRebindGuestSymbolForImage(const struct mach_header *header,
                                 NSString * _Nullable execPath,
                                 const char *symbolName,
                                 void *replacement);

NS_ASSUME_NONNULL_END
