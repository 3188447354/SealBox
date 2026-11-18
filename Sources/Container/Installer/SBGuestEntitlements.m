// SBGuestEntitlements.m — 见头文件注释。
#import "SBGuestEntitlements.h"

#import <mach-o/fat.h>
#import <mach-o/loader.h>

static const uint32_t SBEntMagicEmbeddedSignature = 0xfade0cc0;
static const uint32_t SBEntMagicEntitlements = 0xfade7171;
static const uint32_t SBEntSlotEntitlements = 5;
static const uint32_t SBEntCPUTypeARM64 = 0x0100000C;

static inline uint32_t SBEntReadBE32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static inline uint32_t SBEntReadLE32(const uint8_t *p) {
    return ((uint32_t)p[0]) | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/// 在 data 里找 LC_CODE_SIGNATURE，返回签名区范围。thin arm64 与 fat（取 arm64 slice）。
static BOOL SBEntFindSignature(const uint8_t *data, size_t len,
                               uint32_t *outOff, uint32_t *outSize) {
    if (len < 4) {
        return NO;
    }
    const uint8_t *macho = data;
    size_t machoLen = len;
    uint32_t magicLE = SBEntReadLE32(data);
    if (magicLE == FAT_MAGIC || magicLE == FAT_CIGAM) {
        if (len < sizeof(struct fat_header)) {
            return NO;
        }
        uint32_t nfat = SBEntReadBE32(data + 4);
        const uint8_t *arch = data + sizeof(struct fat_header);
        BOOL found = NO;
        for (uint32_t i = 0; i < nfat; i++) {
            if ((size_t)(arch - data) + sizeof(struct fat_arch) > len) {
                return NO;
            }
            uint32_t cputype = SBEntReadBE32(arch);
            uint32_t offset = SBEntReadBE32(arch + 8);
            uint32_t size = SBEntReadBE32(arch + 12);
            if (cputype == SBEntCPUTypeARM64) {
                if ((uint64_t)offset + size > len) {
                    return NO;
                }
                macho = data + offset;
                machoLen = size;
                found = YES;
                break;
            }
            arch += sizeof(struct fat_arch);
        }
        if (!found) {
            return NO;
        }
        magicLE = SBEntReadLE32(macho);
    }
    if (magicLE != MH_MAGIC_64) {
        return NO;
    }
    if (machoLen < sizeof(struct mach_header_64)) {
        return NO;
    }
    uint32_t ncmds = SBEntReadLE32(macho + 16);
    const uint8_t *lc = macho + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < ncmds; i++) {
        if ((size_t)(lc - macho) + sizeof(struct load_command) > machoLen) {
            return NO;
        }
        uint32_t cmd = SBEntReadLE32(lc);
        uint32_t cmdsize = SBEntReadLE32(lc + 4);
        if (cmdsize < sizeof(struct load_command) ||
            (size_t)(lc - macho) + cmdsize > machoLen) {
            return NO;
        }
        if (cmd == LC_CODE_SIGNATURE) {
            if (cmdsize < 16) {
                return NO;
            }
            *outOff = SBEntReadLE32(lc + 8);
            *outSize = SBEntReadLE32(lc + 12);
            return YES;
        }
        lc += cmdsize;
    }
    return NO;
}

NSString *SBGuestEntitlementsExtractMachOAtPath(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length == 0) {
        return nil;
    }
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    size_t len = (size_t)data.length;
    uint32_t sigOff = 0, sigSize = 0;
    if (!SBEntFindSignature(bytes, len, &sigOff, &sigSize)) {
        return nil;
    }
    if ((uint64_t)sigOff + sigSize > len || sigSize < 16) {
        return nil;
    }
    const uint8_t *sig = bytes + sigOff;
    if (SBEntReadBE32(sig) != SBEntMagicEmbeddedSignature) {
        return nil;
    }
    uint32_t blobLength = SBEntReadBE32(sig + 4);
    uint32_t count = SBEntReadBE32(sig + 8);
    if (blobLength > sigSize || blobLength < 12 || count > 64) {
        return nil;
    }
    const uint8_t *index = sig + 12;
    for (uint32_t i = 0; i < count; i++) {
        if ((size_t)(index - sig) + 8 > blobLength) {
            return nil;
        }
        uint32_t type = SBEntReadBE32(index);
        uint32_t offset = SBEntReadBE32(index + 4);
        index += 8;
        if (type != SBEntSlotEntitlements) {
            continue;
        }
        if (offset + 8 > blobLength) {
            return nil;
        }
        const uint8_t *blob = sig + offset;
        if (SBEntReadBE32(blob) != SBEntMagicEntitlements) {
            return nil;
        }
        uint32_t blobLen = SBEntReadBE32(blob + 4);
        if (blobLen < 8 || offset + blobLen > blobLength) {
            return nil;
        }
        NSData *xmlData = [NSData dataWithBytes:blob + 8 length:blobLen - 8];
        return [[NSString alloc] initWithData:xmlData encoding:NSUTF8StringEncoding];
    }
    return nil;
}

/// 把以 oldTeam 开头的 "OLDTEAM.rest" 换成 "TEAM.rest"；不以旧 Team 开头的不动。
static NSString *SBEntRewritePrefixedString(NSString *value, NSString *oldTeam, NSString *teamID) {
    if (!oldTeam || oldTeam.length == 0 || [oldTeam isEqualToString:teamID]) {
        return value;
    }
    NSString *prefix = [oldTeam stringByAppendingString:@"."];
    if ([value hasPrefix:prefix]) {
        return [teamID stringByAppendingString:[value substringFromIndex:prefix.length - 1]];
    }
    return value;
}

NSString *SBGuestEntitlementsRewrittenForTeam(NSString *entitlementsXML, NSString *teamID) {
    if (!entitlementsXML || entitlementsXML.length == 0 || !teamID || teamID.length == 0) {
        return nil;
    }
    NSData *xmlData = [entitlementsXML dataUsingEncoding:NSUTF8StringEncoding];
    if (!xmlData) {
        return nil;
    }
    NSError *parseError = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:xmlData
                                                         options:NSPropertyListMutableContainers
                                                          format:NULL
                                                           error:&parseError];
    if (!plist || ![plist isKindOfClass:[NSMutableDictionary class]]) {
        return nil;
    }
    NSMutableDictionary *dict = (NSMutableDictionary *)plist;
    NSString *oldTeam = nil;
    id teamValue = dict[@"team-identifier"];
    if ([teamValue isKindOfClass:[NSString class]]) {
        oldTeam = (NSString *)teamValue;
    }
    // Via 这类 App 没有 team-identifier，只有 com.apple.developer.team-identifier。
    if (!oldTeam) {
        id devTeamValue = dict[@"com.apple.developer.team-identifier"];
        if ([devTeamValue isKindOfClass:[NSString class]]) {
            oldTeam = (NSString *)devTeamValue;
        }
    }
    if (!oldTeam) {
        id appID = dict[@"application-identifier"];
        if ([appID isKindOfClass:[NSString class]]) {
            NSRange dot = [(NSString *)appID rangeOfString:@"."];
            if (dot.location != NSNotFound && dot.location > 0) {
                oldTeam = [(NSString *)appID substringToIndex:dot.location];
            }
        }
    }
    id appID = dict[@"application-identifier"];
    if ([appID isKindOfClass:[NSString class]]) {
        dict[@"application-identifier"] = SBEntRewritePrefixedString((NSString *)appID, oldTeam, teamID);
    }
    dict[@"team-identifier"] = teamID;
    // com.apple.developer.team-identifier 与 team-identifier 是同一个 Team 的
    // 两种写法：原包有哪个就改哪个，不能留一个旧 Team 在 entitlements 里。
    if (dict[@"com.apple.developer.team-identifier"] != nil) {
        dict[@"com.apple.developer.team-identifier"] = teamID;
    }
    for (NSString *key in @[@"keychain-access-groups", @"application-groups"]) {
        id groups = dict[key];
        if (![groups isKindOfClass:[NSArray class]]) {
            continue;
        }
        NSMutableArray *rewritten = [NSMutableArray arrayWithCapacity:[(NSArray *)groups count]];
        for (id item in (NSArray *)groups) {
            if ([item isKindOfClass:[NSString class]]) {
                [rewritten addObject:SBEntRewritePrefixedString((NSString *)item, oldTeam, teamID)];
            } else {
                [rewritten addObject:item];
            }
        }
        dict[key] = rewritten;
    }
    NSError *writeError = nil;
    NSData *outData = [NSPropertyListSerialization dataWithPropertyList:dict
                                                                 format:NSPropertyListXMLFormat_v1_0
                                                                options:0
                                                                  error:&writeError];
    if (!outData) {
        return nil;
    }
    return [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
}

/// Team ID / Bundle ID 只允许字母数字、点、横杠、下划线——拼进 XML 时不转义也安全。
static BOOL SBEntIsSafeIdentifier(NSString *value) {
    if (!value || value.length == 0) {
        return NO;
    }
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                               @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_"];
    return [[value stringByTrimmingCharactersInSet:allowed] isEqualToString:@""];
}

NSString *SBGuestEntitlementsMinimalForTeam(NSString *teamID, NSString *bundleID) {
    if (!SBEntIsSafeIdentifier(teamID) || !SBEntIsSafeIdentifier(bundleID)) {
        return nil;
    }
    NSString *appID = [NSString stringWithFormat:@"%@.%@", teamID, bundleID];
    return [NSString stringWithFormat:
            @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            @"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
            @"\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
            @"<plist version=\"1.0\">\n"
            @"<dict>\n"
            @"\t<key>application-identifier</key>\n"
            @"\t<string>%@</string>\n"
            @"\t<key>team-identifier</key>\n"
            @"\t<string>%@</string>\n"
            @"\t<key>get-task-allow</key>\n"
            @"\t<false/>\n"
            @"\t<key>keychain-access-groups</key>\n"
            @"\t<array>\n"
            @"\t\t<string>%@</string>\n"
            @"\t</array>\n"
            @"</dict>\n"
            @"</plist>\n",
            appID, teamID, appID];
}

NSString *SBGuestEntitlementsForExecutableAtPath(NSString *path, NSString *teamID, NSString *bundleID) {
    NSString *original = SBGuestEntitlementsExtractMachOAtPath(path);
    if (original) {
        NSString *rewritten = SBGuestEntitlementsRewrittenForTeam(original, teamID);
        if (rewritten) {
            return rewritten;
        }
    }
    return SBGuestEntitlementsMinimalForTeam(teamID, bundleID);
}
