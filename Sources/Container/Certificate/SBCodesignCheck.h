// SBCodesignCheck.h — 手动解析 Mach-O 代码签名（superblob / CodeDirectory），
// 不依赖 Code Signing Services。
//
// 背景：0.2.2 第一轮 CI 实证——SecStaticCodeCreateWithPath、
// SecCodeCopySigningInformation、SecStaticCode 等符号在 iOS SDK 的 Swift 接口
// 里不存在（cannot find in scope）；它们是 macOS-only API，iOS 上没有。
// 所以读 Team 与校验签名都改成手动解析 CodeDirectory（大端字段，见 .m）。
//
// 能力边界（说清楚，不夸大）：这里校验的是“签名结构完整、每页内容哈希与
// CodeDirectory 里存的哈希一致、CMS 签名块可解析且证书链完整（叶子 +
// WWDR 中间证书 + 根，自签单证书也算完整）、叶子未过期、CMS 摘要与
// CodeDirectory 对得上、备用 CodeDirectory 页哈希与特殊槽哈希全过”；
// CMS 签名本身的密码学验签（RSA/ECDSA 验签、证书链的系统信任评估）是
// dyld 在加载时做的事，这里不做、也做不了。逐项全过仍被 dyld 拒绝时，
// 调用方靠“上次启动死在 dlopen 签名失败”触发强制重签（见 SBInstaller）。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SBCodesignCheck : NSObject

/// 读 Mach-O 的 Team ID（CodeDirectory 的 teamOffset 处字符串）。
/// 无签名、无 Team 或解析失败返回 nil。
+ (nullable NSString *)teamIdentifierAtPath:(NSString *)path;

/// 结构校验签名（0.2.12 收紧）：superblob 与 CodeDirectory 可解析、
/// identifier 非空、每页内容哈希与 CodeDirectory 存的哈希一致、CMS 签名块
/// 可解析且证书链完整、叶子未过期、CMS 摘要与 CodeDirectory 对得上、
/// 备用 CodeDirectory 页哈希与特殊槽哈希全过。
/// 失败时 error 的 localizedDescription 带中文原因。
+ (BOOL)validateSignatureAtPath:(NSString *)path error:(NSError **)error;

/// 逐项签名检查（0.2.10 报错日志用，0.2.12 扩到 CMS 全项）：不早退，
/// 各字段独立记；返回字典：
///   valid（BOOL）= identifier 在位 && CMS 逐项全过（可解析、链完整、
///     叶子未过期、摘要对上）&& 页哈希全过 && 备用 CD 页哈希全过 &&
///     特殊槽全过
///   hasCMS（BOOL）、pageHashOK（BOOL）、firstBadPage（NSNumber/NSNull）
///   pageCount（NSNumber）、teamID（NSString/NSNull）
///   identifier（NSString/NSNull）、error（NSString/NSNull）
///   structureOK（BOOL，superblob + 主 CD 是否解析成功；失败时各逐项
///     字段均为缺省值，调用方只报 error、不逐项点名）
///   cmsLength（NSNumber，CMS DER 字节数）、cmsCertCount（NSNumber）
///   cmsHasWWDR（BOOL，中间证书是不是 Apple WWDR）
///   cmsChainComplete（BOOL）、cmsCDHashOK（BOOL）
///   cmsLeafCN / cmsIntermediateCN（NSString/NSNull）
///   cmsLeafExpiry（NSString/NSNull，原始 UTCTime，如 270421170219Z）
///   cmsLeafExpired（BOOL）、cmsError（NSString/NSNull，CMS 具体坏因）
///   hasAltCD（BOOL）、altPageHashOK（BOOL，无备用 CD 时记 YES）
///   altFirstBadPage（NSNumber/NSNull）
///   specialSlotsOK（BOOL）、badSpecialSlot（NSNumber/NSNull，槽号）
/// 无 Team 时 teamID 记 NSNull（只验结构，不判 Team 对不对——
/// Team 对不对由调用方拿 teamID 对比宿主 Team 再决定）。
+ (NSDictionary *)signatureDetailAtPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
