// SBCodesignCheck.h — 手动解析 Mach-O 代码签名（superblob / CodeDirectory），
// 不依赖 Code Signing Services。
//
// 背景：0.2.2 第一轮 CI 实证——SecStaticCodeCreateWithPath、
// SecCodeCopySigningInformation、SecStaticCode 等符号在 iOS SDK 的 Swift 接口
// 里不存在（cannot find in scope）；它们是 macOS-only API，iOS 上没有。
// 所以读 Team 与校验签名都改成手动解析 CodeDirectory（大端字段，见 .m）。
//
// 能力边界（说清楚，不夸大）：这里校验的是“签名结构完整、每页内容哈希与
// CodeDirectory 里存的哈希一致、有 CMS 签名块”；CMS 的密码学验链（证书链
// 是否被 Apple 认）是 dyld 在加载时做的事，这里不做、也做不了。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SBCodesignCheck : NSObject

/// 读 Mach-O 的 Team ID（CodeDirectory 的 teamOffset 处字符串）。
/// 无签名、无 Team 或解析失败返回 nil。
+ (nullable NSString *)teamIdentifierAtPath:(NSString *)path;

/// 结构校验签名：superblob 与 CodeDirectory 可解析、identifier 非空、
//  每页内容哈希与 CodeDirectory 存的哈希一致、CMS 签名块存在。
/// 失败时 error 的 localizedDescription 带中文原因。
+ (BOOL)validateSignatureAtPath:(NSString *)path error:(NSError **)error;

/// 逐项签名检查（0.2.10 报错日志用）：不早退，CMS / 页哈希 /
/// Team / identifier 各自验、各自记；返回字典：
///   valid（BOOL）= identifier 在位 && CMS 在位 && 页哈希全过
///   hasCMS（BOOL）、pageHashOK（BOOL）、firstBadPage（NSNumber/NSNull）
///   pageCount（NSNumber）、teamID（NSString/NSNull）
///   identifier（NSString/NSNull）、error（NSString/NSNull）
/// 无 Team 时 teamID 记 NSNull（只验结构，不判 Team 对不对——
/// Team 对不对由调用方拿 teamID 对比宿主 Team 再决定）。
+ (NSDictionary *)signatureDetailAtPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
