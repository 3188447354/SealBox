// SBGuestEntitlements.h — 客 App entitlements 提取与改写（0.2.5，LiveContainer 复刻）。
//
// 客 App 签名时 entitlements 的来源（按优先级）：
//   1. 原包签名里 slot 5 的 entitlements XML，Team 前缀换成导入证书的 Team；
//   2. 原包没有（或读不出/改写失败）时合成最小项：application-identifier、
//      team-identifier、get-task-allow=false、keychain-access-groups。
// framework / dylib 不需要 entitlements：调用方不给它们调本模块，签名时传空即可。
// appex 各自用自己的 Bundle ID 与原 entitlements 走同一流程。
//
// 读签名用 SBCodesignCheck 同款手写解析（superblob 大端、slot 5、blob magic
// 0xfade7171），不依赖 codesign 工具。改写用 NSPropertyListSerialization 解析
// XML plist、改键、再序列化回 XML。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 从 Mach-O 文件的原签名里读 entitlements XML（slot 5）。
/// 无签名、slot 5 缺失、解析失败时返回 nil。
/// 支持 thin arm64 与 fat（取 arm64 slice）。
NSString * _Nullable SBGuestEntitlementsExtractMachOAtPath(NSString *path);

/// 把 entitlements XML 里的 Team 前缀换成 teamID。
/// 改写项：application-identifier（前缀）、team-identifier（整值）、
/// keychain-access-groups 与 application-groups 里以旧 Team 开头的元素。
/// 旧 Team 从原 XML 的 team-identifier 取，取不到时从 application-identifier
/// 的首段取；两个都取不到时只补 team-identifier。
/// XML 解析失败或序列化失败时返回 nil（调用方改用最小项合成）。
NSString * _Nullable SBGuestEntitlementsRewrittenForTeam(NSString *entitlementsXML,
                                                        NSString *teamID);

/// 合成最小 entitlements：application-identifier、team-identifier、
/// get-task-allow=false、keychain-access-groups（仅 TEAM.bundleID 一项）。
/// teamID / bundleID 含 XML 不安全字符时返回 nil。
NSString * _Nullable SBGuestEntitlementsMinimalForTeam(NSString *teamID,
                                                      NSString *bundleID);

/// 给一个可执行文件取签名用 entitlements：先原包提取+改写，失败则合成最小项。
/// 始终返回非 nil（除非 teamID / bundleID 本身非法）。
NSString * _Nullable SBGuestEntitlementsForExecutableAtPath(NSString *path,
                                                           NSString *teamID,
                                                           NSString *bundleID);

NS_ASSUME_NONNULL_END
