// SBCodesignCheck.m — 手动解析 Mach-O 代码签名。
//
// 布局（与 ZSign 写出的签名一致，字段全大端）：
// - Mach-O：thin arm64（MH_MAGIC_64）或 fat（取 arm64 slice）；
//   LC_CODE_SIGNATURE（0x1d）给出签名区 [dataoff, dataoff + datasize)。
// - superblob：magic 0xfade0cc0，length，count，后跟 count 个
//   {type, offset}；type 0 = CodeDirectory，type 0x10000 = CMS 签名块。
// - CodeDirectory：magic 0xfade0c02，length，version，flags，hashOffset，
//   identOffset，nSpecialSlots，nCodeSlots，codeLimit，hashSize，hashType，
//   platform，pageSize（log2），spare2，scatterOffset（version >= 0x20100），
//   teamOffset（version >= 0x20200），之后是 spare3 / codeLimit64 / execSeg*。
//   哈希槽布局（0.2.2 实测纠正）：hashOffset 指向第 0 个代码页槽；
//   nSpecialSlots 个特殊槽以负索引存在它前面（第 -k 个在 hashOffset - k*hashSize 处）。
//   例外（0x20500，App Store 加密应用才有）：该版本在偏移 92 处多一个
//   preEncryptOffset——解密后页面的哈希表；hashOffset 表存的是加密前原始页面
//   的哈希，对不上磁盘文件（Via 1.9.0 实测：preEncryptOffset=124 处的表才与
//   磁盘页面哈希一致）。所以 version >= 0x20500 且 preEncryptOffset 非零时，
//   代码表改取 preEncryptOffset；特殊槽仍以 hashOffset 为准。
//   第 i 页覆盖文件字节 [i*pageSize, min((i+1)*pageSize, codeLimit))，
//   槽在代码表起点 + i*hashSize。
//   hashType：1 = SHA-1，2 = SHA-256，3 = SHA-256 截断取前 20 字节，4 = SHA-384。
#import "SBCodesignCheck.h"

#import <CommonCrypto/CommonCrypto.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>

static const uint32_t SBCSMagicEmbeddedSignature = 0xfade0cc0;
static const uint32_t SBCSMagicCodeDirectory = 0xfade0c02;
static const uint32_t SBCSlotCodeDirectory = 0;
static const uint32_t SBCSlotSignatureSlot = 0x10000;
static const uint32_t SBCPUTypeARM64 = 0x0100000C;

static inline uint32_t SBReadBE32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static inline uint32_t SBReadLE32(const uint8_t *p) {
    return ((uint32_t)p[0]) | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

typedef struct {
    const uint8_t *cd; // CodeDirectory 起点（签名区内）
    uint32_t cdLength;
    uint32_t version;
    uint32_t hashOffset;
    uint32_t identOffset;
    uint32_t nSpecialSlots;
    uint32_t nCodeSlots;
    uint32_t codeLimit;
    uint8_t hashSize;
    uint8_t hashType;
    uint8_t pageSizeLog2;
    uint32_t teamOffset; // 0 = 无 Team
    uint32_t preEncryptOffset; // 0x20500+ 才有；0 = 无 pre-encrypt 表
    uint32_t codeHashOffset; // 代码页槽表起点（见文件头注释的 0x20500 例外）
    BOOL hasSignatureSlot;
} SBCodeDirectoryInfo;

static NSError *SBCodeSignError(NSString *reason) {
    return [NSError errorWithDomain:@"SBCodesignCheck"
                               code:1
                           userInfo:@{ NSLocalizedDescriptionKey: reason }];
}

/// 在 data（长度 len）里找 LC_CODE_SIGNATURE，返回签名区范围。
/// 支持 thin arm64 与 fat（取 arm64 slice）。
static BOOL SBFindSignature(const uint8_t *data, size_t len,
                            uint32_t *outOff, uint32_t *outSize,
                            NSString **outReason) {
    if (len < 4) {
        *outReason = @"文件太小，不是 Mach-O";
        return NO;
    }
    const uint8_t *macho = data;
    size_t machoLen = len;
    uint32_t magicLE = SBReadLE32(data);
    if (magicLE == FAT_MAGIC || magicLE == FAT_CIGAM) {
        // fat：头与 arch 表全大端，取 arm64 slice。
        if (len < sizeof(struct fat_header)) {
            *outReason = @"fat 头不完整";
            return NO;
        }
        uint32_t nfat = SBReadBE32(data + 4);
        const uint8_t *arch = data + sizeof(struct fat_header);
        BOOL found = NO;
        for (uint32_t i = 0; i < nfat; i++) {
            if ((size_t)(arch - data) + sizeof(struct fat_arch) > len) {
                *outReason = @"fat arch 表越界";
                return NO;
            }
            uint32_t cputype = SBReadBE32(arch);
            uint32_t offset = SBReadBE32(arch + 8);
            uint32_t size = SBReadBE32(arch + 12);
            if (cputype == SBCPUTypeARM64) {
                if ((uint64_t)offset + size > len) {
                    *outReason = @"arm64 slice 越界";
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
            *outReason = @"fat 包里没有 arm64 slice";
            return NO;
        }
        magicLE = SBReadLE32(macho);
    }
    if (magicLE != MH_MAGIC_64) {
        *outReason = @"不是 64 位 Mach-O";
        return NO;
    }
    if (machoLen < sizeof(struct mach_header_64)) {
        *outReason = @"Mach-O 头不完整";
        return NO;
    }
    uint32_t ncmds = SBReadLE32(macho + 16);
    const uint8_t *lc = macho + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < ncmds; i++) {
        if ((size_t)(lc - macho) + sizeof(struct load_command) > machoLen) {
            *outReason = @"load command 越界";
            return NO;
        }
        uint32_t cmd = SBReadLE32(lc);
        uint32_t cmdsize = SBReadLE32(lc + 4);
        if (cmdsize < sizeof(struct load_command)
            || (size_t)(lc - macho) + cmdsize > machoLen) {
            *outReason = @"load command 长度非法";
            return NO;
        }
        if (cmd == LC_CODE_SIGNATURE) {
            if (cmdsize < sizeof(struct linkedit_data_command)) {
                *outReason = @"LC_CODE_SIGNATURE 长度非法";
                return NO;
            }
            uint32_t dataoff = SBReadLE32(lc + 8);
            uint32_t datasize = SBReadLE32(lc + 12);
            if (dataoff == 0 || datasize == 0
                || (uint64_t)dataoff + datasize > machoLen) {
                *outReason = @"签名区范围非法";
                return NO;
            }
            *outOff = dataoff;
            *outSize = datasize;
            return YES;
        }
        lc += cmdsize;
    }
    *outReason = @"没有 LC_CODE_SIGNATURE，未签名";
    return NO;
}

/// 解析 superblob + CodeDirectory。data 是整个文件内容，sigOff/sigSize 是签名区。
static BOOL SBParseCodeDirectory(const uint8_t *data, size_t len,
                                 uint32_t sigOff, uint32_t sigSize,
                                 SBCodeDirectoryInfo *out,
                                 NSString **outReason) {
    const uint8_t *sig = data + sigOff;
    if (sigSize < 12 || SBReadBE32(sig) != SBCSMagicEmbeddedSignature) {
        *outReason = @"签名区不是 superblob";
        return NO;
    }
    uint32_t blobLength = SBReadBE32(sig + 4);
    uint32_t count = SBReadBE32(sig + 8);
    if (blobLength > sigSize || 12 + count * 8 > sigSize) {
        *outReason = @"superblob 长度非法";
        return NO;
    }
    const uint8_t *cd = NULL;
    uint32_t cdLength = 0;
    BOOL hasSignatureSlot = NO;
    for (uint32_t i = 0; i < count; i++) {
        if ((uint64_t)12 + (uint64_t)(i + 1) * 8 > sigSize) {
            *outReason = @"superblob 索引越界";
            return NO;
        }
        const uint8_t *entry = sig + 12 + i * 8;
        uint32_t type = SBReadBE32(entry);
        uint32_t offset = SBReadBE32(entry + 4);
        if (offset >= sigSize) {
            *outReason = @"superblob 索引越界";
            return NO;
        }
        if (type == SBCSlotCodeDirectory && cd == NULL) {
            cd = sig + offset;
            if (sigSize - offset < 4) {
                *outReason = @"CodeDirectory 越界";
                return NO;
            }
            cdLength = SBReadBE32(cd + 4);
            if (cdLength < 44 || offset + cdLength > sigSize) {
                *outReason = @"CodeDirectory 长度非法";
                return NO;
            }
        } else if (type == SBCSlotSignatureSlot) {
            hasSignatureSlot = YES;
        }
    }
    if (cd == NULL) {
        *outReason = @"superblob 里没有 CodeDirectory";
        return NO;
    }
    if (SBReadBE32(cd) != SBCSMagicCodeDirectory) {
        *outReason = @"CodeDirectory magic 不对";
        return NO;
    }
    memset(out, 0, sizeof(*out));
    out->cd = cd;
    out->cdLength = cdLength;
    out->version = SBReadBE32(cd + 8);
    out->hashOffset = SBReadBE32(cd + 16);
    out->identOffset = SBReadBE32(cd + 20);
    out->nSpecialSlots = SBReadBE32(cd + 24);
    out->nCodeSlots = SBReadBE32(cd + 28);
    out->codeLimit = SBReadBE32(cd + 32);
    out->hashSize = cd[36];
    out->hashType = cd[37];
    out->pageSizeLog2 = cd[39];
    out->hasSignatureSlot = hasSignatureSlot;
    if (out->version >= 0x20200) {
        out->teamOffset = SBReadBE32(cd + 48);
    }
    if (out->version >= 0x20500) {
        out->preEncryptOffset = SBReadBE32(cd + 92);
    }
    // 代码表起点：0x20500+ 且有 pre-encrypt 表时取它，否则取 hashOffset。
    out->codeHashOffset = (out->version >= 0x20500 && out->preEncryptOffset != 0)
        ? out->preEncryptOffset : out->hashOffset;
    if (out->version < 0x20000) {
        *outReason = @"CodeDirectory 版本太老";
        return NO;
    }
    if (out->hashOffset == 0
        || out->hashOffset < (uint64_t)out->nSpecialSlots * out->hashSize
        || (uint64_t)out->codeHashOffset + (uint64_t)out->nCodeSlots * out->hashSize > cdLength) {
        *outReason = @"CodeDirectory 哈希表越界";
        return NO;
    }
    if (out->identOffset == 0 || out->identOffset >= cdLength) {
        *outReason = @"CodeDirectory identifier 越界";
        return NO;
    }
    if (out->codeLimit == 0 || (uint64_t)out->codeLimit > len) {
        *outReason = @"CodeDirectory codeLimit 越界";
        return NO;
    }
    if (out->pageSizeLog2 > 20) {
        *outReason = @"CodeDirectory pageSize 非法";
        return NO;
    }
    (void)len;
    return YES;
}

/// 读 CodeDirectory 里的 C 字符串（identOffset / teamOffset 处），限定在 cdLength 内。
static NSString *SBReadCDString(const SBCodeDirectoryInfo *info, uint32_t offset) {
    if (offset == 0 || offset >= info->cdLength) {
        return nil;
    }
    const char *start = (const char *)info->cd + offset;
    size_t maxLen = info->cdLength - offset;
    size_t len = 0;
    while (len < maxLen && start[len] != '\0') {
        len++;
    }
    if (len == 0) {
        return nil;
    }
    return [[NSString alloc] initWithBytes:start length:len encoding:NSUTF8StringEncoding];
}

/// 对一页内容算哈希（hashType 决定算法），与槽里存的哈希比对。
static BOOL SBVerifyPageHash(const uint8_t *page, size_t pageLen,
                             uint8_t hashType, uint8_t hashSize,
                             const uint8_t *expected) {
    uint8_t digest[CC_SHA384_DIGEST_LENGTH];
    size_t digestLen = 0;
    switch (hashType) {
        case 1: // SHA-1
            CC_SHA1(page, (CC_LONG)pageLen, digest);
            digestLen = CC_SHA1_DIGEST_LENGTH;
            break;
        case 2: // SHA-256
            CC_SHA256(page, (CC_LONG)pageLen, digest);
            digestLen = CC_SHA256_DIGEST_LENGTH;
            break;
        case 3: // SHA-256 截断
            CC_SHA256(page, (CC_LONG)pageLen, digest);
            digestLen = CC_SHA256_DIGEST_LENGTH;
            break;
        case 4: // SHA-384
            CC_SHA384(page, (CC_LONG)pageLen, digest);
            digestLen = CC_SHA384_DIGEST_LENGTH;
            break;
        default:
            return NO;
    }
    if (hashSize > digestLen) {
        return NO;
    }
    return memcmp(digest, expected, hashSize) == 0;
}

@implementation SBCodesignCheck

+ (nullable NSString *)teamIdentifierAtPath:(NSString *)path {
    NSData *fileData = [NSData dataWithContentsOfFile:path];
    if (fileData == nil) {
        return nil;
    }
    const uint8_t *bytes = (const uint8_t *)fileData.bytes;
    size_t len = fileData.length;
    uint32_t sigOff = 0, sigSize = 0;
    NSString *reason = nil;
    if (!SBFindSignature(bytes, len, &sigOff, &sigSize, &reason)) {
        return nil;
    }
    SBCodeDirectoryInfo info;
    if (!SBParseCodeDirectory(bytes, len, sigOff, sigSize, &info, &reason)) {
        return nil;
    }
    return SBReadCDString(&info, info.teamOffset);
}

+ (BOOL)validateSignatureAtPath:(NSString *)path error:(NSError **)error {
    NSData *fileData = [NSData dataWithContentsOfFile:path];
    if (fileData == nil) {
        if (error) {
            *error = SBCodeSignError(@"读不到待校验的文件");
        }
        return NO;
    }
    const uint8_t *bytes = (const uint8_t *)fileData.bytes;
    size_t len = fileData.length;
    uint32_t sigOff = 0, sigSize = 0;
    NSString *reason = nil;
    if (!SBFindSignature(bytes, len, &sigOff, &sigSize, &reason)) {
        if (error) {
            *error = SBCodeSignError([NSString stringWithFormat:@"签名结构无效：%@", reason]);
        }
        return NO;
    }
    SBCodeDirectoryInfo info;
    if (!SBParseCodeDirectory(bytes, len, sigOff, sigSize, &info, &reason)) {
        if (error) {
            *error = SBCodeSignError([NSString stringWithFormat:@"签名结构无效：%@", reason]);
        }
        return NO;
    }
    NSString *identifier = SBReadCDString(&info, info.identOffset);
    if (identifier == nil || identifier.length == 0) {
        if (error) {
            *error = SBCodeSignError(@"签名结构无效：CodeDirectory 没有 identifier");
        }
        return NO;
    }
    if (!info.hasSignatureSlot) {
        if (error) {
            *error = SBCodeSignError(@"签名结构无效：superblob 里没有 CMS 签名块");
        }
        return NO;
    }
    // 每页内容哈希与 CodeDirectory 里存的哈希逐页比对。
    uint32_t pageSize = 1u << info.pageSizeLog2;
    for (uint32_t i = 0; i < info.nCodeSlots; i++) {
        uint64_t pageStart = (uint64_t)i * pageSize;
        if (pageStart >= info.codeLimit) {
            if (error) {
                *error = SBCodeSignError(@"签名结构无效：代码页超出 codeLimit");
            }
            return NO;
        }
        uint64_t remaining = (uint64_t)info.codeLimit - pageStart;
        size_t pageLen = (size_t)MIN((uint64_t)pageSize, remaining);
        // 代码槽 i 在代码表起点 + i*hashSize（特殊槽在 hashOffset 之前，不占这里）。
        const uint8_t *expected = info.cd + info.codeHashOffset
            + (uint64_t)i * info.hashSize;
        if (!SBVerifyPageHash(bytes + pageStart, pageLen,
                             info.hashType, info.hashSize, expected)) {
            if (error) {
                *error = SBCodeSignError([NSString stringWithFormat:@"签名校验失败：第 %u 页内容哈希与签名里存的不一致，文件可能被改过", i]);
            }
            return NO;
        }
    }
    return YES;
}

@end
