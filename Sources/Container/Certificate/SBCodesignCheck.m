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
// - CMS 签名块（superblob 槽 0x10000）：blob 头 8 字节后是 PKCS#7 SignedData
//   （Apple codesign 写 BER 不定长、外层 SEQ 是 30 80；OpenSSL/ZSign 写定长
//   DER——解析器两种都支持，见 SBDerReadTLV）。
//   0.2.12：逐项检查 CMS：可解析、证书链完整（叶子→WWDR 中间证书→根，
//   自签单证书也算完整）、叶子未过期、SignerInfo 的 messageDigest 与文件里
//   的 CodeDirectory 对得上；备用 CodeDirectory（槽 0x1000，SHA-256，dyld
//   优先用）页哈希、特殊槽（entitlements 等）哈希也都验。
//   0.2.14：补上 0.2.12 明确写在能力边界之外的两项——CMS 签名值本身的
//   密码学验签（叶子公钥 + SecKeyVerifySignature，验 SignerInfo 签名属性
//   的 RSA/ECDSA 签名值；0.2.12 称“做不了”是错的：自研 DER 解析器 + 公开
//   Security API 就能做，不依赖 macOS-only 的 SecStaticCode），以及 Apple
//   签名属性 9.1（cdhashes plist）/ 9.2（各 CD 的完整哈希）与主/备用 CD
//   的比对。逐项全过仍被 dyld 拒绝时，这两项是唯一能把它与“签名本身坏
//   了”区分开的证据；调用方仍靠“上次启动死在 dlopen 签名失败”触发强制
//   重签（见 SBInstaller）。
#import "SBCodesignCheck.h"

#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>

static const uint32_t SBCSMagicEmbeddedSignature = 0xfade0cc0;
static const uint32_t SBCSMagicCodeDirectory = 0xfade0c02;
static const uint32_t SBCSlotCodeDirectory = 0;
static const uint32_t SBCSlotAlternateCodeDirectory = 0x1000;
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
} SBCodeDirectoryInfo;

/// 一次签名解析的全部结果：主 CD + 备用 CD + CMS 槽 + superblob 索引。
typedef struct {
    SBCodeDirectoryInfo cd; // 主 CodeDirectory（槽 0）
    BOOL hasAltCD;
    SBCodeDirectoryInfo altCD; // 备用 CodeDirectory（槽 0x1000，SHA-256）
    BOOL hasSignatureSlot;
    uint32_t cmsOffset; // CMS blob 在签名区内的偏移（0 = 无）
    uint32_t cmsBlobLength; // CMS blob 长度字段（含 8 字节头），0 = 无
    uint32_t superblobLength; // superblob 自身的 length 字段（0.2.14：LC 一致性用）
    uint32_t slotTypes[16]; // superblob 索引（特殊槽哈希用）
    uint32_t slotOffsets[16];
    uint32_t slotCount;
} SBSignatureInfo;

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

/// 解析单个 CodeDirectory blob 的字段（cd 指向 blob 起点，avail 是签名区内
/// 剩余长度，fileLen 是整个文件长度，供 codeLimit 校验用）。
static BOOL SBParseCDBlob(const uint8_t *cd, uint32_t avail, size_t fileLen,
                          SBCodeDirectoryInfo *out,
                          NSString **outReason) {
    // 0.2.3: 读 magic（cd+0）+ length（cd+4）需要 8 字节，不是 4 字节；
    // 只保证 4 字节时 cd+4 的读会越界（损坏的签名才触发）。
    if (avail < 8) {
        *outReason = @"CodeDirectory 越界";
        return NO;
    }
    uint32_t cdLength = SBReadBE32(cd + 4);
    if (cdLength < 44 || cdLength > avail) {
        *outReason = @"CodeDirectory 长度非法";
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
    // 0.2.3: teamOffset（cd+48）需要 cdLength ≥ 52，preEncryptOffset（cd+92）
    // 需要 cdLength ≥ 96；只校验 ≥44 时，损坏的签名会在这里越读。
    if (out->version >= 0x20200) {
        if (cdLength < 52) {
            *outReason = @"CodeDirectory 太短，没有 teamOffset";
            return NO;
        }
        out->teamOffset = SBReadBE32(cd + 48);
    }
    if (out->version >= 0x20500) {
        if (cdLength < 96) {
            *outReason = @"CodeDirectory 太短，没有 preEncryptOffset";
            return NO;
        }
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
    if (out->codeLimit == 0 || (uint64_t)out->codeLimit > fileLen) {
        *outReason = @"CodeDirectory codeLimit 越界";
        return NO;
    }
    if (out->pageSizeLog2 > 20) {
        *outReason = @"CodeDirectory pageSize 非法";
        return NO;
    }
    return YES;
}

/// 解析 superblob：主 CodeDirectory、备用 CodeDirectory（槽 0x1000，
/// SHA-256，dyld 优先用）、CMS 签名块（槽 0x10000）与 superblob 索引。
/// data 是整个文件内容，sigOff/sigSize 是签名区。
static BOOL SBParseSignature(const uint8_t *data, size_t len,
                             uint32_t sigOff, uint32_t sigSize,
                             SBSignatureInfo *out,
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
    memset(out, 0, sizeof(*out));
    out->superblobLength = blobLength;
    BOOL foundCD = NO;
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
        if (out->slotCount < 16) {
            out->slotTypes[out->slotCount] = type;
            out->slotOffsets[out->slotCount] = offset;
            out->slotCount++;
        }
        if (type == SBCSlotCodeDirectory && !foundCD) {
            if (!SBParseCDBlob(sig + offset, sigSize - offset, len, &out->cd, outReason)) {
                return NO;
            }
            foundCD = YES;
        } else if (type == SBCSlotAlternateCodeDirectory && !out->hasAltCD) {
            if (!SBParseCDBlob(sig + offset, sigSize - offset, len, &out->altCD, outReason)) {
                return NO;
            }
            out->hasAltCD = YES;
        } else if (type == SBCSlotSignatureSlot) {
            out->hasSignatureSlot = YES;
            out->cmsOffset = offset;
            if (sigSize - offset < 8) {
                *outReason = @"CMS 签名块越界";
                return NO;
            }
            out->cmsBlobLength = SBReadBE32(sig + offset + 4);
        }
    }
    if (!foundCD) {
        *outReason = @"superblob 里没有 CodeDirectory";
        return NO;
    }
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

/// 逐页验一个 CodeDirectory 的代码页哈希（与旧 validateSignature 同款循环）。
static BOOL SBVerifyCDPages(const uint8_t *bytes,
                            const SBCodeDirectoryInfo *info,
                            uint32_t *firstBadPage,
                            NSString **outReason) {
    uint32_t pageSize = 1u << info->pageSizeLog2;
    for (uint32_t i = 0; i < info->nCodeSlots; i++) {
        uint64_t pageStart = (uint64_t)i * pageSize;
        if (pageStart >= info->codeLimit) {
            if (firstBadPage) {
                *firstBadPage = UINT32_MAX; // 结构错，不是某页哈希错
            }
            if (outReason) {
                *outReason = @"代码页超出 codeLimit";
            }
            return NO;
        }
        uint64_t remaining = (uint64_t)info->codeLimit - pageStart;
        size_t pageLen = (size_t)MIN((uint64_t)pageSize, remaining);
        // 代码槽 i 在代码表起点 + i*hashSize（特殊槽在 hashOffset 之前，不占这里）。
        const uint8_t *expected = info->cd + info->codeHashOffset
            + (uint64_t)i * info->hashSize;
        if (!SBVerifyPageHash(bytes + pageStart, pageLen,
                             info->hashType, info->hashSize, expected)) {
            if (firstBadPage) {
                *firstBadPage = i;
            }
            return NO;
        }
    }
    return YES;
}

/// 验特殊槽（1..7：info.plist、requirements、resources、entitlements 等）：
/// 每个槽的 blob 在 superblob 里的长度取“下一槽偏移 - 本槽偏移”（末槽到
/// 签名区尾）；blob 哈希与该 CD 的特殊槽哈希表（hashOffset - type*hashSize）
/// 逐字节比对。badSlot 记首个不符的槽号。
static BOOL SBVerifySpecialSlots(const uint8_t *sig, uint32_t sigSize,
                                 const SBSignatureInfo *sigInfo,
                                 const SBCodeDirectoryInfo *info,
                                 uint32_t *badSlot) {
    if (info->nSpecialSlots == 0) {
        return YES;
    }
    // 槽偏移按升序排（索引里一般已是升序，但不依赖它）。
    uint32_t offsets[16];
    uint32_t n = sigInfo->slotCount < 16 ? sigInfo->slotCount : 16;
    for (uint32_t i = 0; i < n; i++) {
        offsets[i] = sigInfo->slotOffsets[i];
    }
    for (uint32_t i = 0; i < n; i++) {
        for (uint32_t j = i + 1; j < n; j++) {
            if (offsets[j] < offsets[i]) {
                uint32_t t = offsets[i];
                offsets[i] = offsets[j];
                offsets[j] = t;
            }
        }
    }
    for (uint32_t s = 0; s < sigInfo->slotCount; s++) {
        uint32_t type = sigInfo->slotTypes[s];
        if (type < 1 || type > 7 || type > info->nSpecialSlots) {
            continue;
        }
        uint32_t offset = sigInfo->slotOffsets[s];
        // 下一槽偏移（没有就到签名区尾）即本 blob 长度。
        uint32_t end = sigSize;
        for (uint32_t i = 0; i < n; i++) {
            if (offsets[i] > offset && offsets[i] < end) {
                end = offsets[i];
            }
        }
        uint32_t blobLen = end - offset;
        if (blobLen < 8) {
            if (badSlot) {
                *badSlot = type;
            }
            return NO;
        }
        const uint8_t *expected = info->cd + info->hashOffset
            - (uint64_t)type * info->hashSize;
        if (!SBVerifyPageHash(sig + offset, blobLen,
                             info->hashType, info->hashSize, expected)) {
            if (badSlot) {
                *badSlot = type;
            }
            return NO;
        }
    }
    return YES;
}

// MARK: - DER / CMS 解析（0.2.12）
//
// 只实现 PKCS#7 SignedData 需要的子集：TLV（定长 DER + 不定长 BER）、
// 证书集、SignerInfo 的 messageDigest 属性。解析是严格的：标签不对、
// 长度越界、容器没在 TLV 边界上结束，全部当解析失败（不静默跳过——
// 0.2.11 的教训：只查“槽在不在”会把截断/空 CMS 当成好的放行）。

typedef struct {
    uint8_t tag;
    const uint8_t *content; // 内容起点
    uint32_t contentLen;
    uint32_t totalLen; // 头 + 内容（不定长时含结尾的 EOC）
} SBDerTLV;

#define SBDerMaxDepth 16
#define SBDerMaxChildren 16

/// 读一个 TLV。off 是 buf 内偏移（buf 长 len）。不定长（0x80）时扫子项
/// 直到 EOC（00 00），contentLen 即 EOC 之前的子项总长。
static BOOL SBDerReadTLV(const uint8_t *buf, size_t len, size_t off,
                         SBDerTLV *out, NSString **reason, int depth) {
    if (depth > SBDerMaxDepth) {
        if (reason) *reason = @"DER 嵌套太深";
        return NO;
    }
    if (off + 2 > len) {
        if (reason) *reason = @"DER 越界";
        return NO;
    }
    uint8_t tag = buf[off];
    if (tag == 0x1F) { // 多字节标签：CMS 里不需要
        if (reason) *reason = @"DER 多字节标签不支持";
        return NO;
    }
    uint8_t lenByte = buf[off + 1];
    size_t headerLen = 2;
    uint32_t contentLen = 0;
    BOOL indefinite = NO;
    if (lenByte == 0x80) {
        indefinite = YES;
    } else if (lenByte & 0x80) {
        uint8_t n = lenByte & 0x7F;
        if (n == 0 || n > 4 || off + 2 + n > len) {
            if (reason) *reason = @"DER 长度字段非法";
            return NO;
        }
        for (uint8_t i = 0; i < n; i++) {
            contentLen = (contentLen << 8) | buf[off + 2 + i];
        }
        headerLen = 2 + n;
    } else {
        contentLen = lenByte;
    }
    if (indefinite) {
        // 扫子项直到 EOC。
        size_t p = off + headerLen;
        while (YES) {
            if (p + 2 > len) {
                if (reason) *reason = @"DER 不定长内容没有 EOC";
                return NO;
            }
            if (buf[p] == 0x00 && buf[p + 1] == 0x00) {
                contentLen = (uint32_t)(p - (off + headerLen));
                out->tag = tag;
                out->content = buf + off + headerLen;
                out->contentLen = contentLen;
                out->totalLen = (uint32_t)((p + 2) - off);
                return YES;
            }
            SBDerTLV child;
            if (!SBDerReadTLV(buf, len, p, &child, reason, depth + 1)) {
                return NO;
            }
            p += child.totalLen;
        }
    }
    if (off + headerLen + contentLen > len) {
        if (reason) *reason = @"DER 内容越界";
        return NO;
    }
    out->tag = tag;
    out->content = buf + off + headerLen;
    out->contentLen = contentLen;
    out->totalLen = (uint32_t)(headerLen + contentLen);
    return YES;
}

/// 列出一个构造型 TLV 的全部子项（必须恰好在内容尾结束）。
typedef struct {
    SBDerTLV items[SBDerMaxChildren];
    uint32_t count;
} SBDerChildrenList;

static BOOL SBDerChildren(const uint8_t *buf, size_t len,
                          const SBDerTLV *parent,
                          SBDerChildrenList *out, NSString **reason, int depth) {
    size_t start = (size_t)(parent->content - buf);
    size_t end = start + parent->contentLen;
    size_t p = start;
    out->count = 0;
    while (p < end) {
        if (out->count >= SBDerMaxChildren) {
            if (reason) *reason = @"DER 子项太多";
            return NO;
        }
        SBDerTLV child;
        if (!SBDerReadTLV(buf, len, p, &child, reason, depth + 1)) {
            return NO;
        }
        if (p + child.totalLen > end) {
            if (reason) *reason = @"DER 子项越出容器";
            return NO;
        }
        out->items[out->count++] = child;
        p += child.totalLen;
    }
    if (p != end) {
        if (reason) *reason = @"DER 容器长度与子项不符";
        return NO;
    }
    return YES;
}

/// 格里高利历转天数（Howard Hinnant 算法），供证书有效期比较用。
static int64_t SBDaysFromCivil(int y, unsigned m, unsigned d) {
    y -= m <= 2;
    int64_t era = (y >= 0 ? y : y - 399) / 400;
    unsigned yoe = (unsigned)(y - era * 400);
    unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + (int64_t)doe - 719468;
}

/// 解析 UTCTime（YYMMDDHHMMSSZ）或 GeneralizedTime（YYYYMMDDHHMMSSZ，
/// 允许小数秒）。返回自 epoch 的秒数，失败返回 INT64_MIN。
static int64_t SBDerTimeToEpoch(const SBDerTLV *timeTLV) {
    const uint8_t *s = timeTLV->content;
    uint32_t n = timeTLV->contentLen;
    if (timeTLV->tag == 0x17) { // UTCTime
        if (n != 13 || s[12] != 'Z') return INT64_MIN;
        int yy = (s[0] - '0') * 10 + (s[1] - '0');
        int year = yy < 50 ? 2000 + yy : 1900 + yy;
        int mo = (s[2] - '0') * 10 + (s[3] - '0');
        int d = (s[4] - '0') * 10 + (s[5] - '0');
        int h = (s[6] - '0') * 10 + (s[7] - '0');
        int mi = (s[8] - '0') * 10 + (s[9] - '0');
        int sec = (s[10] - '0') * 10 + (s[11] - '0');
        if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || sec > 60) return INT64_MIN;
        return SBDaysFromCivil(year, (unsigned)mo, (unsigned)d) * 86400 + h * 3600 + mi * 60 + sec;
    }
    if (timeTLV->tag == 0x18) { // GeneralizedTime
        if (n < 15) return INT64_MIN;
        if (s[14] != 'Z') {
            // 允许小数秒：YYYYMMDDHHMMSS.fffZ
            if (n < 17 || s[14] != '.') return INT64_MIN;
            uint32_t i = 15;
            while (i < n && s[i] >= '0' && s[i] <= '9') i++;
            if (i >= n || s[i] != 'Z') return INT64_MIN;
        }
        int year = (s[0] - '0') * 1000 + (s[1] - '0') * 100 + (s[2] - '0') * 10 + (s[3] - '0');
        int mo = (s[4] - '0') * 10 + (s[5] - '0');
        int d = (s[6] - '0') * 10 + (s[7] - '0');
        int h = (s[8] - '0') * 10 + (s[9] - '0');
        int mi = (s[10] - '0') * 10 + (s[11] - '0');
        int sec = (s[12] - '0') * 10 + (s[13] - '0');
        if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || sec > 60) return INT64_MIN;
        return SBDaysFromCivil(year, (unsigned)mo, (unsigned)d) * 86400 + h * 3600 + mi * 60 + sec;
    }
    return INT64_MIN;
}

/// 从一个 TLV 值里拷字符串（PrintableString / UTF8String / TeletexString
/// 原样拷；BMPString 由 UTF-16BE 转 UTF-8）。
static void SBDerCopyString(const SBDerTLV *value, char *out, size_t outSize) {
    if (outSize == 0) return;
    out[0] = '\0';
    if (value->tag == 0x1E) { // BMPString
        size_t n = value->contentLen / 2;
        size_t j = 0;
        for (size_t i = 0; i < n && j + 1 < outSize; i++) {
            uint16_t ch = ((uint16_t)value->content[i * 2] << 8) | value->content[i * 2 + 1];
            if (ch < 0x80) {
                out[j++] = (char)ch;
            } else if (ch < 0x800 && j + 2 < outSize) {
                out[j++] = (char)(0xC0 | (ch >> 6));
                out[j++] = (char)(0x80 | (ch & 0x3F));
            } else if (j + 3 < outSize) {
                out[j++] = (char)(0xE0 | (ch >> 12));
                out[j++] = (char)(0x80 | ((ch >> 6) & 0x3F));
                out[j++] = (char)(0x80 | (ch & 0x3F));
            } else {
                break;
            }
        }
        out[j] = '\0';
        return;
    }
    size_t n = value->contentLen < outSize - 1 ? value->contentLen : outSize - 1;
    memcpy(out, value->content, n);
    out[n] = '\0';
}

/// 在 Name（RDNSequence）里找 CN（OID 2.5.4.3）。nameTLVStart 是原始 TLV
///（含标签头），在里面扫 OID 字节再读后面的值 TLV。
static void SBDerNameCN(const uint8_t *nameTLVStart, uint32_t nameTLVLen,
                        char *out, size_t outSize) {
    static const uint8_t kCNOID[5] = { 0x06, 0x03, 0x55, 0x04, 0x03 };
    if (outSize == 0) return;
    out[0] = '\0';
    if (nameTLVLen < 5) return;
    for (uint32_t i = 0; i + 5 <= nameTLVLen; i++) {
        if (memcmp(nameTLVStart + i, kCNOID, 5) != 0) continue;
        SBDerTLV value;
        if (!SBDerReadTLV(nameTLVStart, nameTLVLen, i + 5, &value, NULL, 0)) continue;
        if (value.tag != 0x0C && value.tag != 0x13 && value.tag != 0x14
            && value.tag != 0x1E && value.tag != 0x1C) {
            continue;
        }
        SBDerCopyString(&value, out, outSize);
        return;
    }
}

/// 字节串里是否含子串（memmem 的手写版）。
static BOOL SBBytesContain(const uint8_t *hay, size_t hayLen,
                           const char *needle) {
    size_t nLen = strlen(needle);
    if (nLen == 0 || hayLen < nLen) return NO;
    for (size_t i = 0; i + nLen <= hayLen; i++) {
        if (memcmp(hay + i, needle, nLen) == 0) return YES;
    }
    return NO;
}

typedef struct {
    const uint8_t *issuerTLV; // 完整 TLV（含标签头），供链比对用
    uint32_t issuerTLVLen;
    const uint8_t *subjectTLV;
    uint32_t subjectTLVLen;
    const uint8_t *spkiTLV; // subjectPublicKeyInfo 完整 TLV（0.2.14：CMS 验签用叶子公钥）
    uint32_t spkiTLVLen;
    char cn[128];
    char issuerCN[128];
    int64_t notAfter; // INT64_MIN = 解析失败
    char notAfterRaw[32];
} SBDerCert;

#define SBMaxCerts 8

/// 解析一张证书：只取 TBS 里的 issuer / validity.notAfter / subject，
/// 以及 subject/issuer 的 CN。标签顺序严格校验（0.2.12 原型实证：
/// 截断的 CMS 会把损坏区读成一串空 TLV，必须靠标签顺序拦住）。
static BOOL SBParseCert(const SBDerTLV *certTLV,
                        const uint8_t *buf, size_t len,
                        SBDerCert *out, NSString **reason) {
    if (certTLV->tag != 0x30) {
        if (reason) *reason = @"证书不是 SEQUENCE";
        return NO;
    }
    SBDerChildrenList kids;
    if (!SBDerChildren(buf, len, certTLV, &kids, reason, 0)) return NO;
    if (kids.count < 1 || kids.items[0].tag != 0x30) {
        if (reason) *reason = @"证书里没有 TBSCertificate";
        return NO;
    }
    SBDerChildrenList tbs;
    if (!SBDerChildren(buf, len, &kids.items[0], &tbs, reason, 0)) return NO;
    // TBS：[0] 版本（可选）、INTEGER 序列号、SEQ 签名算法、SEQ issuer、
    // SEQ validity、SEQ subject。
    uint32_t idx = 0;
    if (idx < tbs.count && tbs.items[idx].tag == 0xA0) idx++;
    static const uint8_t kExpected[5] = { 0x02, 0x30, 0x30, 0x30, 0x30 };
    static const char *kNames[5] = { "serial", "signature", "issuer", "validity", "subject" };
    for (int k = 0; k < 5; k++) {
        if (idx + (uint32_t)k >= tbs.count || tbs.items[idx + k].tag != kExpected[k]
            || tbs.items[idx + k].contentLen == 0) {
            if (reason) {
                *reason = [NSString stringWithFormat:@"证书 TBS 字段 %@ 缺失或为空",
                           [NSString stringWithUTF8String:kNames[k]]];
            }
            return NO;
        }
    }
    SBDerTLV issuer = tbs.items[idx + 2];
    SBDerTLV validity = tbs.items[idx + 3];
    SBDerTLV subject = tbs.items[idx + 4];
    SBDerChildrenList times;
    if (!SBDerChildren(buf, len, &validity, &times, reason, 0)) return NO;
    if (times.count < 2
        || (times.items[0].tag != 0x17 && times.items[0].tag != 0x18)
        || (times.items[1].tag != 0x17 && times.items[1].tag != 0x18)) {
        if (reason) *reason = @"证书 validity 时间标签不对";
        return NO;
    }
    int64_t notAfter = SBDerTimeToEpoch(&times.items[1]);
    if (notAfter == INT64_MIN) {
        if (reason) *reason = @"证书到期日解析失败";
        return NO;
    }
    memset(out, 0, sizeof(*out));
    // 完整 TLV 的起点 = 内容起点 - 头长。
    const uint8_t *issuerStart = issuer.content - (issuer.totalLen - issuer.contentLen);
    const uint8_t *subjectStart = subject.content - (subject.totalLen - subject.contentLen);
    out->issuerTLV = issuerStart;
    out->issuerTLVLen = issuer.totalLen;
    out->subjectTLV = subjectStart;
    out->subjectTLVLen = subject.totalLen;
    // TBS 第 6 个字段是 subjectPublicKeyInfo（0.2.14：CMS 签名验签用叶子公钥）。
    // 没有它时解析仍成功（链检查不需要公钥），验签步骤再报缺失。
    if (idx + 5 < tbs.count && tbs.items[idx + 5].tag == 0x30) {
        const SBDerTLV *spki = &tbs.items[idx + 5];
        out->spkiTLV = spki->content - (spki->totalLen - spki->contentLen);
        out->spkiTLVLen = spki->totalLen;
    }
    SBDerNameCN(subjectStart, subject.totalLen, out->cn, sizeof(out->cn));
    SBDerNameCN(issuerStart, issuer.totalLen, out->issuerCN, sizeof(out->issuerCN));
    out->notAfter = notAfter;
    size_t rawLen = times.items[1].contentLen < sizeof(out->notAfterRaw) - 1
        ? times.items[1].contentLen : sizeof(out->notAfterRaw) - 1;
    memcpy(out->notAfterRaw, times.items[1].content, rawLen);
    out->notAfterRaw[rawLen] = '\0';
    return YES;
}

/// 按 hashType 算摘要（1=SHA-1，2=SHA-256，3=SHA-256，4=SHA-384）。
/// 返回摘要长度（0 = 类型不认）。
static size_t SBHashBytes(uint8_t hashType, const uint8_t *data, size_t len,
                          uint8_t *out) {
    switch (hashType) {
        case 1:
            CC_SHA1(data, (CC_LONG)len, out);
            return CC_SHA1_DIGEST_LENGTH;
        case 2:
        case 3:
            CC_SHA256(data, (CC_LONG)len, out);
            return CC_SHA256_DIGEST_LENGTH;
        case 4:
            CC_SHA384(data, (CC_LONG)len, out);
            return CC_SHA384_DIGEST_LENGTH;
        default:
            return 0;
    }
}

/// 把一段内容包成 SET OF 的 DER（0x31 + 定长长度 + 内容）。CMS 的签名
/// 属性在 SignerInfo 里是 [0] 隐式标签（0xA0），验签时要按 SET OF（0x31）
/// 重新编码再算摘要——内容字节不变，只换标签与长度编码（不定长也一并
/// 转定长）。返回 malloc 的缓冲（调用方 free），失败返回 NULL。
static uint8_t *SBBuildSetOfDER(const uint8_t *content, uint32_t contentLen,
                                uint32_t *outLen) {
    uint8_t lenBytes[5];
    size_t lenLen = 0;
    if (contentLen < 128) {
        lenBytes[0] = (uint8_t)contentLen;
        lenLen = 1;
    } else if (contentLen < 256) {
        lenBytes[0] = 0x81;
        lenBytes[1] = (uint8_t)contentLen;
        lenLen = 2;
    } else if (contentLen < 65536) {
        lenBytes[0] = 0x82;
        lenBytes[1] = (uint8_t)(contentLen >> 8);
        lenBytes[2] = (uint8_t)contentLen;
        lenLen = 3;
    } else {
        return NULL;
    }
    uint32_t total = (uint32_t)(1 + lenLen + contentLen);
    uint8_t *buf = (uint8_t *)malloc(total);
    if (!buf) return NULL;
    buf[0] = 0x31;
    memcpy(buf + 1, lenBytes, lenLen);
    memcpy(buf + 1 + lenLen, content, contentLen);
    if (outLen) *outLen = total;
    return buf;
}

/// 从 SPKI 里取公钥算法 OID（rsaEncryption / id-ecPublicKey），
/// 返回 YES 表示认出 RSA（*isRSA=YES）或 EC（*isRSA=NO）。
static BOOL SBSPKIKeyType(const uint8_t *spkiTLV, uint32_t spkiTLVLen,
                          const uint8_t *der, size_t derLen, BOOL *isRSA) {
    static const uint8_t kRSAOID[9] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01 };
    static const uint8_t kECOID[7] = { 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 };
    SBDerTLV spki;
    size_t off = (size_t)(spkiTLV - der);
    if (spkiTLVLen == 0 || off + spkiTLVLen > derLen) {
        return NO;
    }
    if (!SBDerReadTLV(der, derLen, off, &spki, NULL, 0) || spki.tag != 0x30) {
        return NO;
    }
    SBDerChildrenList kids;
    if (!SBDerChildren(der, derLen, &spki, &kids, NULL, 0)
        || kids.count < 1 || kids.items[0].tag != 0x30) {
        return NO;
    }
    SBDerChildrenList alg;
    if (!SBDerChildren(der, derLen, &kids.items[0], &alg, NULL, 0)
        || alg.count < 1 || alg.items[0].tag != 0x06) {
        return NO;
    }
    const SBDerTLV *oid = &alg.items[0];
    if (oid->contentLen == 9 && memcmp(oid->content, kRSAOID, 9) == 0) {
        *isRSA = YES;
        return YES;
    }
    if (oid->contentLen == 7 && memcmp(oid->content, kECOID, 7) == 0) {
        *isRSA = NO;
        return YES;
    }
    return NO;
}

/// 0.2.14：CMS 签名值本身的密码学验签。
/// 输入：签名属性 TLV（[0] 项，没有则为 NULL——此时签的是内容本身，
/// 即主 CD 字节）、签名值、SignerInfo 的摘要算法、叶子证书的 SPKI。
/// 做法：摘要 = hash(SET OF 编码的签名属性)（或无属性时 hash(CD)），
/// 再用叶子公钥 + SecKeyVerifySignature 验 RSA/ECDSA 签名值。
/// 成功返回 YES；失败把原因写进 error（256 字节缓冲）。
static BOOL SBVerifyCMSSignature(const SBDerTLV *signedAttrs,
                                 const uint8_t *signature, uint32_t signatureLen,
                                 uint8_t hashType,
                                 const uint8_t *leafSPKI, uint32_t leafSPKILen,
                                 const uint8_t *der, size_t derLen,
                                 const SBCodeDirectoryInfo *cdInfo,
                                 char *error, size_t errorSize) {
    if (hashType == 0) {
        snprintf(error, errorSize, "CMS 签名摘要算法不认");
        return NO;
    }
    if (signature == NULL || signatureLen == 0) {
        snprintf(error, errorSize, "CMS 里没有签名值");
        return NO;
    }
    if (leafSPKI == NULL || leafSPKILen == 0) {
        snprintf(error, errorSize, "叶子证书里没有公钥，无法验签");
        return NO;
    }
    // 待验摘要：有签名属性时 hash(SET OF 编码的属性)，否则 hash(CD)。
    uint8_t digest[CC_SHA384_DIGEST_LENGTH];
    size_t digestLen = 0;
    uint8_t *setDER = NULL;
    uint32_t setDERLen = 0;
    if (signedAttrs != NULL) {
        setDER = SBBuildSetOfDER(signedAttrs->content, signedAttrs->contentLen, &setDERLen);
        if (!setDER) {
            snprintf(error, errorSize, "签名属性重编码失败");
            return NO;
        }
        digestLen = SBHashBytes(hashType, setDER, setDERLen, digest);
        free(setDER);
    } else {
        digestLen = SBHashBytes(hashType, cdInfo->cd, cdInfo->cdLength, digest);
    }
    if (digestLen == 0) {
        snprintf(error, errorSize, "CMS 签名摘要算法不支持（hashType=%u）", hashType);
        return NO;
    }
    BOOL isRSA = YES;
    if (!SBSPKIKeyType(leafSPKI, leafSPKILen, der, derLen, &isRSA)) {
        snprintf(error, errorSize, "叶子证书公钥算法不认（不是 RSA/ECDSA）");
        return NO;
    }
    CFDataRef keyData = CFDataCreate(NULL, leafSPKI, (CFIndex)leafSPKILen);
    if (!keyData) {
        snprintf(error, errorSize, "叶子公钥数据构造失败");
        return NO;
    }
    NSDictionary *attrs = @{
        (__bridge id)kSecAttrKeyType: isRSA ? (__bridge id)kSecAttrKeyTypeRSA : (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
    };
    CFErrorRef cfError = NULL;
    SecKeyRef key = SecKeyCreateWithData(keyData, (__bridge CFDictionaryRef)attrs, &cfError);
    CFRelease(keyData);
    if (!key) {
        if (cfError) CFRelease(cfError);
        snprintf(error, errorSize, "叶子公钥加载失败（SPKI 不是合法的 %@ 公钥）", isRSA ? @"RSA" : @"EC");
        return NO;
    }
    SecKeyAlgorithm algorithm = NULL;
    if (isRSA) {
        if (hashType == 1) algorithm = kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1;
        else if (hashType == 2 || hashType == 3) algorithm = kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256;
        else if (hashType == 4) algorithm = kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA384;
    } else {
        if (hashType == 1) algorithm = kSecKeyAlgorithmECDSASignatureDigestX962SHA1;
        else if (hashType == 2 || hashType == 3) algorithm = kSecKeyAlgorithmECDSASignatureDigestX962SHA256;
        else if (hashType == 4) algorithm = kSecKeyAlgorithmECDSASignatureDigestX962SHA384;
    }
    if (algorithm == NULL) {
        CFRelease(key);
        snprintf(error, errorSize, "不支持的签名算法组合（%@ + hashType=%u）",
                 isRSA ? @"RSA" : @"EC", hashType);
        return NO;
    }
    CFDataRef digestData = CFDataCreate(NULL, digest, (CFIndex)digestLen);
    CFDataRef sigData = CFDataCreate(NULL, signature, (CFIndex)signatureLen);
    if (!digestData || !sigData) {
        if (digestData) CFRelease(digestData);
        if (sigData) CFRelease(sigData);
        CFRelease(key);
        snprintf(error, errorSize, "验签数据构造失败");
        return NO;
    }
    cfError = NULL;
    BOOL ok = SecKeyVerifySignature(key, algorithm, digestData, sigData, &cfError);
    if (!ok) {
        NSString *desc = cfError ? (__bridge_transfer NSString *)CFErrorCopyDescription(cfError) : nil;
        snprintf(error, errorSize, "CMS 签名值验签不过（叶子公钥验签名属性失败%s%s）",
                 desc ? "：" : "", desc ? desc.UTF8String : "");
        if (cfError) CFRelease(cfError);
    }
    CFRelease(digestData);
    CFRelease(sigData);
    CFRelease(key);
    return ok;
}

/// 0.2.14：Apple 签名属性 9.1 / 9.2 与主/备用 CD 的比对。
/// 9.1（cdhashes plist）：每项是对应 CD 的哈希截断到 20 字节——这是
/// Apple 自己的格式（Via 实测：cdhashes[1] 是 SHA256(备用 CD) 的前 20
/// 字节；codesign 单 CD 时只有 1 项，是 SHA256(主 CD) 的前 20 字节），
/// ZSign 同款写法不是缺陷；比的是值对不对、项数对不对。
/// 9.2：每项 SEQ{摘要算法 OID, 完整哈希}，必须与对应 CD 的完整哈希
/// 相等；有备用 CD 时必须有一项 sha256 对上备用 CD。
/// 成功返回 YES；失败把原因写进 error。
static BOOL SBVerifyCMSAppleAttrs(const uint8_t *plistData, uint32_t plistLen,
                                  const uint8_t *nine2TLVs[8], const uint32_t nine2Lens[8],
                                  uint32_t nine2Count,
                                  const SBCodeDirectoryInfo *cdInfo,
                                  const SBCodeDirectoryInfo *altCDInfo,
                                  char *error, size_t errorSize) {
    if (plistData == NULL || plistLen == 0) {
        snprintf(error, errorSize, "CMS 里没有 Apple 9.1（cdhashes）属性");
        return NO;
    }
    NSData *plistNSData = [NSData dataWithBytes:plistData length:plistLen];
    NSError *plistError = nil;
    id plistObj = [NSPropertyListSerialization propertyListWithData:plistNSData
                                                            options:0
                                                             format:NULL
                                                              error:&plistError];
    if (![plistObj isKindOfClass:[NSDictionary class]]) {
        snprintf(error, errorSize, "Apple 9.1 属性不是合法 plist（%s）",
                 plistError.localizedDescription.UTF8String ?: "解析失败");
        return NO;
    }
    NSArray *hashes = ((NSDictionary *)plistObj)[@"cdhashes"];
    if (![hashes isKindOfClass:[NSArray class]]) {
        snprintf(error, errorSize, "Apple 9.1 plist 里没有 cdhashes 数组");
        return NO;
    }
    uint32_t expectedCount = altCDInfo != NULL ? 2 : 1;
    if (hashes.count != expectedCount) {
        snprintf(error, errorSize, "Apple 9.1 cdhashes 有 %lu 项，应为 %u 项",
                 (unsigned long)hashes.count, expectedCount);
        return NO;
    }
    const SBCodeDirectoryInfo *cds[2] = { cdInfo, altCDInfo };
    for (uint32_t i = 0; i < expectedCount; i++) {
        NSData *entry = hashes[i];
        if (![entry isKindOfClass:[NSData class]] || entry.length != 20) {
            snprintf(error, errorSize, "Apple 9.1 cdhashes[%u] 不是 20 字节", i);
            return NO;
        }
        uint8_t digest[CC_SHA384_DIGEST_LENGTH];
        size_t digestLen = SBHashBytes(cds[i]->hashType, cds[i]->cd, cds[i]->cdLength, digest);
        if (digestLen == 0 || memcmp(entry.bytes, digest, 20) != 0) {
            snprintf(error, errorSize, "Apple 9.1 cdhashes[%u] 与 CodeDirectory 哈希对不上", i);
            return NO;
        }
    }
    // 9.2：逐项比完整哈希。
    BOOL seenAlt256 = NO;
    for (uint32_t n = 0; n < nine2Count; n++) {
        SBDerTLV seq;
        if (!SBDerReadTLV(nine2TLVs[n], nine2Lens[n], 0, &seq, NULL, 0)
            || seq.tag != 0x30) {
            snprintf(error, errorSize, "Apple 9.2 第 %u 项不是 SEQUENCE", n);
            return NO;
        }
        SBDerChildrenList kids;
        if (!SBDerChildren(nine2TLVs[n], nine2Lens[n], &seq, &kids, NULL, 0)
            || kids.count < 2 || kids.items[0].tag != 0x06 || kids.items[1].tag != 0x04) {
            snprintf(error, errorSize, "Apple 9.2 第 %u 项结构不对", n);
            return NO;
        }
        static const uint8_t kSHA1OID[5] = { 0x2B, 0x0E, 0x03, 0x02, 0x1A };
        static const uint8_t kSHA256OID[9] = { 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01 };
        const SBDerTLV *oid = &kids.items[0];
        const SBDerTLV *hashVal = &kids.items[1];
        const SBCodeDirectoryInfo *target = NULL;
        uint8_t wantType = 0;
        if (oid->contentLen == 5 && memcmp(oid->content, kSHA1OID, 5) == 0) {
            target = cdInfo;
            wantType = 1;
        } else if (oid->contentLen == 9 && memcmp(oid->content, kSHA256OID, 9) == 0) {
            target = altCDInfo != NULL ? altCDInfo : cdInfo;
            wantType = 2;
        } else {
            snprintf(error, errorSize, "Apple 9.2 第 %u 项摘要算法不认", n);
            return NO;
        }
        uint8_t digest[CC_SHA384_DIGEST_LENGTH];
        size_t digestLen = SBHashBytes(wantType, target->cd, target->cdLength, digest);
        if (digestLen == 0 || hashVal->contentLen != digestLen
            || memcmp(hashVal->content, digest, digestLen) != 0) {
            snprintf(error, errorSize, "Apple 9.2 第 %u 项哈希与 CodeDirectory 对不上", n);
            return NO;
        }
        if (altCDInfo != NULL && target == altCDInfo && wantType == 2) {
            seenAlt256 = YES;
        }
    }
    if (altCDInfo != NULL && !seenAlt256) {
        snprintf(error, errorSize, "Apple 9.2 里没有备用 CodeDirectory 的 SHA-256 哈希");
        return NO;
    }
    return YES;
}

typedef struct {
    uint32_t cmsDERLength;
    uint32_t certCount;
    BOOL parseOK;
    BOOL chainComplete;
    BOOL hasWWDR;
    BOOL leafExpired;
    BOOL cdHashOK;
    BOOL signatureValid; // 0.2.14：CMS 签名值密码学验签
    BOOL appleAttrsValid; // 0.2.14：Apple 9.1/9.2 属性与 CD 比对
    char leafCN[128];
    char intermediateCN[128];
    char leafExpiry[32];
    char error[256];
    char signatureError[256]; // 0.2.14：验签失败原因
    char appleAttrsError[256]; // 0.2.14：9.1/9.2 比对失败原因
} SBCMSDetail;

/// 验 CMS 签名块：可解析、链完整、叶子未过期、messageDigest 与 CD 对得上。
/// sig 是签名区起点；cmsOffset/cmsBlobLength 来自 superblob 索引；
/// cdInfo 是主 CodeDirectory（摘要对它算）；altCDInfo 是备用 CodeDirectory，
/// 没有时传 NULL（0.2.14：Apple 9.1/9.2 属性要对备用 CD 算哈希）。
static void SBInspectCMS(const uint8_t *sig, uint32_t sigSize,
                         uint32_t cmsOffset, uint32_t cmsBlobLength,
                         const SBCodeDirectoryInfo *cdInfo,
                         const SBCodeDirectoryInfo *altCDInfo,
                         SBCMSDetail *out) {
    memset(out, 0, sizeof(*out));
    if (cmsBlobLength < 8) {
        snprintf(out->error, sizeof(out->error), "CMS 签名块长度非法");
        return;
    }
    uint32_t derLen = cmsBlobLength - 8;
    out->cmsDERLength = derLen;
    if (derLen == 0 || (uint64_t)cmsOffset + 8 + derLen > sigSize) {
        snprintf(out->error, sizeof(out->error), "CMS 签名块为空或越界");
        return;
    }
    const uint8_t *der = sig + cmsOffset + 8;
    NSString *reason = nil;
    // ContentInfo ::= SEQ { OID, [0] SignedData }
    SBDerTLV top;
    if (!SBDerReadTLV(der, derLen, 0, &top, &reason, 0) || top.tag != 0x30) {
        snprintf(out->error, sizeof(out->error), "CMS 解析失败：%s",
                 reason.UTF8String ?: "外层不是 SEQUENCE");
        return;
    }
    SBDerChildrenList ci;
    if (!SBDerChildren(der, derLen, &top, &ci, &reason, 0)
        || ci.count < 2 || ci.items[0].tag != 0x06 || ci.items[1].tag != 0xA0) {
        snprintf(out->error, sizeof(out->error), "CMS 解析失败：%s",
                 reason.UTF8String ?: "ContentInfo 结构不对");
        return;
    }
    SBDerChildrenList sdWrap;
    if (!SBDerChildren(der, derLen, &ci.items[1], &sdWrap, &reason, 0)
        || sdWrap.count < 1 || sdWrap.items[0].tag != 0x30) {
        snprintf(out->error, sizeof(out->error), "CMS 解析失败：%s",
                 reason.UTF8String ?: "没有 SignedData");
        return;
    }
    SBDerChildrenList sd;
    if (!SBDerChildren(der, derLen, &sdWrap.items[0], &sd, &reason, 0)
        || sd.count < 3 || sd.items[0].tag != 0x02
        || sd.items[1].tag != 0x31 || sd.items[2].tag != 0x30) {
        snprintf(out->error, sizeof(out->error), "CMS 解析失败：%s",
                 reason.UTF8String ?: "SignedData 结构不对");
        return;
    }
    // 证书集 [0] 与签名者信息 SET（位置不固定，按标签找）。
    SBDerCert certs[SBMaxCerts];
    uint32_t certCount = 0;
    const SBDerTLV *signerInfos = NULL;
    for (uint32_t i = 3; i < sd.count; i++) {
        if (sd.items[i].tag == 0xA0 && certCount == 0) {
            SBDerChildrenList certKids;
            if (!SBDerChildren(der, derLen, &sd.items[i], &certKids, &reason, 0)) {
                snprintf(out->error, sizeof(out->error), "CMS 解析失败：%s",
                         reason.UTF8String ?: "证书集结构不对");
                return;
            }
            for (uint32_t c = 0; c < certKids.count; c++) {
                if (certCount >= SBMaxCerts) {
                    snprintf(out->error, sizeof(out->error), "CMS 解析失败：证书太多（>%u 张）", SBMaxCerts);
                    return;
                }
                if (!SBParseCert(&certKids.items[c], der, derLen, &certs[certCount], &reason)) {
                    snprintf(out->error, sizeof(out->error), "CMS 解析失败：%s",
                             reason.UTF8String ?: "证书解析失败");
                    return;
                }
                certCount++;
            }
        } else if (sd.items[i].tag == 0x31 && signerInfos == NULL) {
            signerInfos = &sd.items[i];
        }
    }
    out->certCount = certCount;
    if (signerInfos == NULL) {
        snprintf(out->error, sizeof(out->error), "CMS 解析失败：没有 SignerInfo");
        return;
    }
    SBDerChildrenList siSet;
    if (!SBDerChildren(der, derLen, signerInfos, &siSet, &reason, 0)
        || siSet.count < 1 || siSet.items[0].tag != 0x30) {
        snprintf(out->error, sizeof(out->error), "CMS 解析失败：%s",
                 reason.UTF8String ?: "SignerInfo 不是 SEQUENCE");
        return;
    }
    SBDerChildrenList si;
    if (!SBDerChildren(der, derLen, &siSet.items[0], &si, &reason, 0)
        || si.count < 3 || si.items[0].tag != 0x02
        || si.items[1].tag != 0x30 || si.items[2].tag != 0x30) {
        snprintf(out->error, sizeof(out->error), "CMS 解析失败：%s",
                 reason.UTF8String ?: "SignerInfo 结构不对");
        return;
    }
    // 摘要算法 OID（SignerInfo 的 digestAlgorithm SEQ 的首个 OID）。
    SBDerChildrenList algSeq;
    static const uint8_t kSHA1OID[5] = { 0x2B, 0x0E, 0x03, 0x02, 0x1A };
    static const uint8_t kSHA256OID[9] = { 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01 };
    static const uint8_t kSHA384OID[9] = { 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02 };
    uint8_t hashType = 0;
    if (SBDerChildren(der, derLen, &si.items[2], &algSeq, NULL, 0)
        && algSeq.count >= 1 && algSeq.items[0].tag == 0x06) {
        const SBDerTLV *oid = &algSeq.items[0];
        if (oid->contentLen == 5 && memcmp(oid->content, kSHA1OID, 5) == 0) hashType = 1;
        else if (oid->contentLen == 9 && memcmp(oid->content, kSHA256OID, 9) == 0) hashType = 2;
        else if (oid->contentLen == 9 && memcmp(oid->content, kSHA384OID, 9) == 0) hashType = 4;
    }
    if (hashType == 0) {
        snprintf(out->error, sizeof(out->error), "CMS 解析失败：摘要算法 OID 不认");
        return;
    }
    // 签名属性：messageDigest（OID 1.2.840.113549.1.9.4）、Apple 9.1
    //（1.2.840.113635.100.9.1，cdhashes plist）、Apple 9.2
    //（1.2.840.113635.100.9.2，各 CD 的完整哈希）。三者都在签名属性集里，
    // 0.2.14 一并取出来（验签与属性比对用）；签名值是 SignerInfo 的末字段。
    static const uint8_t kMessageDigestOID[9] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04 };
    static const uint8_t kAppleCDHashesOID[9] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x09, 0x01 };
    static const uint8_t kAppleCDHashOID[9] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x09, 0x02 };
    const uint8_t *msgDigest = NULL;
    uint32_t msgDigestLen = 0;
    SBDerTLV signedAttrsTLV;
    BOOL hasSignedAttrs = NO; // SignerInfo 的 [0] 签名属性集
    const uint8_t *applePlist = NULL;
    uint32_t applePlistLen = 0;
    const uint8_t *nine2TLVs[8];
    uint32_t nine2Lens[8];
    uint32_t nine2Count = 0;
    const uint8_t *cmsSignature = NULL;
    uint32_t cmsSignatureLen = 0;
    for (uint32_t i = 3; i < si.count; i++) {
        if (si.items[i].tag == 0x04 && cmsSignature == NULL) {
            // SignerInfo 末字段：签名值 OCTET STRING。
            cmsSignature = si.items[i].content;
            cmsSignatureLen = si.items[i].contentLen;
            continue;
        }
        if (si.items[i].tag != 0xA0) continue;
        if (!hasSignedAttrs) {
            signedAttrsTLV = si.items[i];
            hasSignedAttrs = YES;
        }
        SBDerChildrenList attrs;
        if (!SBDerChildren(der, derLen, &si.items[i], &attrs, &reason, 0)) {
            snprintf(out->error, sizeof(out->error), "CMS 解析失败：%s",
                     reason.UTF8String ?: "签名属性结构不对");
            return;
        }
        for (uint32_t a = 0; a < attrs.count; a++) {
            if (attrs.items[a].tag != 0x30) continue;
            SBDerChildrenList attr;
            if (!SBDerChildren(der, derLen, &attrs.items[a], &attr, NULL, 0)
                || attr.count < 2 || attr.items[0].tag != 0x06
                || attr.items[0].contentLen != 9
                || attr.items[1].tag != 0x31) {
                continue;
            }
            const uint8_t *oidBytes = attr.items[0].content;
            BOOL isDigest = memcmp(oidBytes, kMessageDigestOID, 9) == 0;
            BOOL is91 = memcmp(oidBytes, kAppleCDHashesOID, 9) == 0;
            BOOL is92 = memcmp(oidBytes, kAppleCDHashOID, 9) == 0;
            if (!isDigest && !is91 && !is92) continue;
            SBDerChildrenList vals;
            if (!SBDerChildren(der, derLen, &attr.items[1], &vals, NULL, 0)
                || vals.count < 1) {
                continue;
            }
            if (isDigest) {
                if (vals.items[0].tag != 0x04) continue;
                msgDigest = vals.items[0].content;
                msgDigestLen = vals.items[0].contentLen;
            } else if (is91) {
                if (vals.items[0].tag != 0x04) continue;
                applePlist = vals.items[0].content;
                applePlistLen = vals.items[0].contentLen;
            } else {
                for (uint32_t v = 0; v < vals.count && nine2Count < 8; v++) {
                    if (vals.items[v].tag != 0x30) continue;
                    const SBDerTLV *seq = &vals.items[v];
                    nine2TLVs[nine2Count] = seq->content - (seq->totalLen - seq->contentLen);
                    nine2Lens[nine2Count] = seq->totalLen;
                    nine2Count++;
                }
            }
        }
    }
    if (msgDigest == NULL) {
        snprintf(out->error, sizeof(out->error), "CMS 解析失败：SignerInfo 里没有 messageDigest 属性");
        return;
    }
    out->parseOK = YES;
    // 链：叶子 = 主体不等于任何其他证书签发者的那张；C2 = 主体等于叶子
    // 签发者的那张；C2 自签、或另有 C3 主体等于 C2 签发者，链才完整。
    // （自签单证书：叶子就是 C2、且自签，算完整——CI 自签宿主就这结构。）
    int leafIdx = -1;
    for (uint32_t i = 0; i < certCount; i++) {
        BOOL isIssuerOfAnother = NO;
        for (uint32_t j = 0; j < certCount; j++) {
            if (i == j) continue;
            if (certs[i].subjectTLVLen == certs[j].issuerTLVLen
                && memcmp(certs[i].subjectTLV, certs[j].issuerTLV, certs[i].subjectTLVLen) == 0) {
                isIssuerOfAnother = YES;
                break;
            }
        }
        if (!isIssuerOfAnother) {
            if (leafIdx >= 0) { leafIdx = -2; break; } // 两张候选叶子
            leafIdx = (int)i;
        }
    }
    if (leafIdx < 0) {
        snprintf(out->error, sizeof(out->error), "CMS 证书链不完整：找不到唯一叶子证书（共 %u 张）", certCount);
        return;
    }
    SBDerCert *leaf = &certs[leafIdx];
    snprintf(out->leafCN, sizeof(out->leafCN), "%s", leaf->cn);
    snprintf(out->leafExpiry, sizeof(out->leafExpiry), "%s", leaf->notAfterRaw);
    int c2Idx = -1;
    for (uint32_t i = 0; i < certCount; i++) {
        if (i == (uint32_t)leafIdx) continue;
        if (certs[i].subjectTLVLen == leaf->issuerTLVLen
            && memcmp(certs[i].subjectTLV, leaf->issuerTLV, leaf->issuerTLVLen) == 0) {
            c2Idx = (int)i;
            break;
        }
    }
    BOOL selfSignedLeaf = (leaf->subjectTLVLen == leaf->issuerTLVLen
        && memcmp(leaf->subjectTLV, leaf->issuerTLV, leaf->subjectTLVLen) == 0);
    if (c2Idx < 0 && !selfSignedLeaf) {
        snprintf(out->error, sizeof(out->error),
                 "CMS 证书链不完整：叶子证书（%s）的签发者（%s）在 CMS 里找不到对应的中间证书",
                 leaf->cn, leaf->issuerCN);
        return;
    }
    if (c2Idx >= 0) {
        SBDerCert *c2 = &certs[c2Idx];
        snprintf(out->intermediateCN, sizeof(out->intermediateCN), "%s", c2->cn);
        out->hasWWDR = SBBytesContain(c2->subjectTLV, c2->subjectTLVLen,
                                     "Worldwide Developer Relations");
        BOOL c2SelfSigned = (c2->subjectTLVLen == c2->issuerTLVLen
            && memcmp(c2->subjectTLV, c2->issuerTLV, c2->subjectTLVLen) == 0);
        if (!c2SelfSigned) {
            BOOL foundC3 = NO;
            for (uint32_t i = 0; i < certCount; i++) {
                if (i == (uint32_t)c2Idx) continue;
                if (certs[i].subjectTLVLen == c2->issuerTLVLen
                    && memcmp(certs[i].subjectTLV, c2->issuerTLV, c2->issuerTLVLen) == 0) {
                    foundC3 = YES;
                    break;
                }
            }
            if (!foundC3) {
                snprintf(out->error, sizeof(out->error),
                         "CMS 证书链不完整：中间证书（%s）的签发者在 CMS 里找不到对应的根证书",
                         c2->cn);
                return;
            }
        }
    } else {
        // 自签叶子：中间证书就是它自己。
        snprintf(out->intermediateCN, sizeof(out->intermediateCN), "%s", leaf->cn);
        out->hasWWDR = NO;
    }
    out->chainComplete = YES;
    // 叶子过期？
    if (leaf->notAfter < (int64_t)time(NULL)) {
        out->leafExpired = YES;
    }
    // messageDigest 与 CodeDirectory 对得上？
    uint8_t digest[CC_SHA384_DIGEST_LENGTH];
    size_t digestLen = 0;
    switch (hashType) {
        case 1:
            CC_SHA1(cdInfo->cd, (CC_LONG)cdInfo->cdLength, digest);
            digestLen = CC_SHA1_DIGEST_LENGTH;
            break;
        case 2:
            CC_SHA256(cdInfo->cd, (CC_LONG)cdInfo->cdLength, digest);
            digestLen = CC_SHA256_DIGEST_LENGTH;
            break;
        case 4:
            CC_SHA384(cdInfo->cd, (CC_LONG)cdInfo->cdLength, digest);
            digestLen = CC_SHA384_DIGEST_LENGTH;
            break;
        default:
            break;
    }
    out->cdHashOK = (digestLen > 0 && msgDigestLen == digestLen
                     && memcmp(digest, msgDigest, digestLen) == 0);
    // 0.2.14：CMS 签名值密码学验签 + Apple 9.1/9.2 属性比对。
    // 链完整是前提（要叶子证书的公钥）；验签失败不抹掉已算出的逐项，
    // 调用方按 signatureValid / appleAttrsValid 各自点名。
    out->signatureValid = SBVerifyCMSSignature(
        hasSignedAttrs ? &signedAttrsTLV : NULL,
        cmsSignature, cmsSignatureLen, hashType,
        leaf->spkiTLV, leaf->spkiTLVLen,
        der, derLen, cdInfo, out->signatureError, sizeof(out->signatureError));
    out->appleAttrsValid = SBVerifyCMSAppleAttrs(
        applePlist, applePlistLen, nine2TLVs, nine2Lens, nine2Count,
        cdInfo, altCDInfo, out->appleAttrsError, sizeof(out->appleAttrsError));
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
    SBSignatureInfo info;
    if (!SBParseSignature(bytes, len, sigOff, sigSize, &info, &reason)) {
        return nil;
    }
    return SBReadCDString(&info.cd, info.cd.teamOffset);
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
    SBSignatureInfo info;
    if (!SBParseSignature(bytes, len, sigOff, sigSize, &info, &reason)) {
        if (error) {
            *error = SBCodeSignError([NSString stringWithFormat:@"签名结构无效：%@", reason]);
        }
        return NO;
    }
    NSString *identifier = SBReadCDString(&info.cd, info.cd.identOffset);
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
    uint32_t firstBadPage = 0;
    if (!SBVerifyCDPages(bytes, &info.cd, &firstBadPage, &reason)) {
        if (error) {
            if (firstBadPage == UINT32_MAX) {
                *error = SBCodeSignError(@"签名结构无效：代码页超出 codeLimit");
            } else {
                *error = SBCodeSignError([NSString stringWithFormat:@"签名校验失败：第 %u 页内容哈希与签名里存的不一致，文件可能被改过", firstBadPage]);
            }
        }
        return NO;
    }
    // 0.2.12：CMS 逐项——可解析、链完整、叶子未过期、摘要与 CD 对得上。
    // 旧版只查“CMS 槽在不在”，截断/空 CMS、缺中间证书、过期叶子、签名后
    // 改 CD 都能混过去，dyld 才在 dlopen 时报 code signature invalid。
    // 0.2.14：再加 CMS 签名值密码学验签 + Apple 9.1/9.2 属性比对。
    SBCMSDetail cms;
    SBInspectCMS(bytes + sigOff, sigSize, info.cmsOffset, info.cmsBlobLength,
                 &info.cd, info.hasAltCD ? &info.altCD : NULL, &cms);
    if (!cms.parseOK || !cms.chainComplete || cms.leafExpired || !cms.cdHashOK
        || !cms.signatureValid || !cms.appleAttrsValid) {
        if (error) {
            if (cms.error[0] != '\0') {
                *error = SBCodeSignError([NSString stringWithFormat:@"签名校验失败：%@", [NSString stringWithUTF8String:cms.error]]);
            } else if (cms.leafExpired) {
                *error = SBCodeSignError([NSString stringWithFormat:@"签名校验失败：叶子证书已过期（到期 %@）", [NSString stringWithUTF8String:cms.leafExpiry]]);
            } else if (!cms.cdHashOK) {
                *error = SBCodeSignError(@"签名校验失败：CMS 摘要与 CodeDirectory 对不上，签名后文件被改过");
            } else if (!cms.signatureValid) {
                *error = SBCodeSignError([NSString stringWithFormat:@"签名校验失败：%@", [NSString stringWithUTF8String:cms.signatureError]]);
            } else if (!cms.appleAttrsValid) {
                *error = SBCodeSignError([NSString stringWithFormat:@"签名校验失败：%@", [NSString stringWithUTF8String:cms.appleAttrsError]]);
            } else {
                *error = SBCodeSignError(@"签名校验失败：CMS 证书链不完整");
            }
        }
        return NO;
    }
    // 备用 CodeDirectory（SHA-256，dyld 优先用）页哈希。
    if (info.hasAltCD) {
        uint32_t altBadPage = 0;
        if (!SBVerifyCDPages(bytes, &info.altCD, &altBadPage, &reason)) {
            if (error) {
                if (altBadPage == UINT32_MAX) {
                    *error = SBCodeSignError(@"签名结构无效：备用 CodeDirectory 代码页超出 codeLimit");
                } else {
                    *error = SBCodeSignError([NSString stringWithFormat:@"签名校验失败：备用 CodeDirectory 第 %u 页内容哈希与签名里存的不一致", altBadPage]);
                }
            }
            return NO;
        }
    }
    // 特殊槽（entitlements 等）哈希。
    uint32_t badSlot = 0;
    if (!SBVerifySpecialSlots(bytes + sigOff, sigSize, &info, &info.cd, &badSlot)) {
        if (error) {
            *error = SBCodeSignError([NSString stringWithFormat:@"签名校验失败：特殊槽 %u 哈希与签名里存的不一致，签名后文件被改过", badSlot]);
        }
        return NO;
    }
    return YES;
}

+ (NSDictionary *)signatureDetailAtPath:(NSString *)path {
    NSMutableDictionary *detail = [NSMutableDictionary dictionary];
    detail[@"valid"] = @NO;
    detail[@"hasCMS"] = @NO;
    detail[@"pageHashOK"] = @NO;
    detail[@"firstBadPage"] = [NSNull null];
    detail[@"pageCount"] = @0;
    detail[@"teamID"] = [NSNull null];
    detail[@"identifier"] = [NSNull null];
    detail[@"error"] = [NSNull null];
    detail[@"structureOK"] = @NO; // superblob + 主 CD 是否解析成功
    // 0.2.12 新增字段（缺省 = 未验出好结果，调用方按“坏”处理）。
    detail[@"cmsLength"] = @0;
    detail[@"cmsCertCount"] = @0;
    detail[@"cmsHasWWDR"] = @NO;
    detail[@"cmsChainComplete"] = @NO;
    detail[@"cmsCDHashOK"] = @NO;
    detail[@"cmsLeafCN"] = [NSNull null];
    detail[@"cmsIntermediateCN"] = [NSNull null];
    detail[@"cmsLeafExpiry"] = [NSNull null];
    detail[@"cmsLeafExpired"] = @NO;
    detail[@"cmsError"] = [NSNull null];
    detail[@"hasAltCD"] = @NO;
    detail[@"altPageHashOK"] = @YES; // 无备用 CD 时无可验，记 YES
    detail[@"altFirstBadPage"] = [NSNull null];
    detail[@"specialSlotsOK"] = @NO;
    detail[@"badSpecialSlot"] = [NSNull null];
    // 0.2.14 新增字段（缺省 = 未验出好结果，调用方按“坏”处理）。
    detail[@"cmsSignatureValid"] = @NO;
    detail[@"cmsSignatureError"] = [NSNull null];
    detail[@"cmsAppleAttrsValid"] = @NO;
    detail[@"cmsAppleAttrsError"] = [NSNull null];
    detail[@"lcSignatureOK"] = @NO;
    detail[@"lcDataOff"] = @0;
    detail[@"lcDataSize"] = @0;
    detail[@"superblobLength"] = @0;

    NSData *fileData = [NSData dataWithContentsOfFile:path];
    if (fileData == nil) {
        detail[@"error"] = @"读不到待校验的文件";
        return detail;
    }
    const uint8_t *bytes = (const uint8_t *)fileData.bytes;
    size_t len = fileData.length;
    uint32_t sigOff = 0, sigSize = 0;
    NSString *reason = nil;
    if (!SBFindSignature(bytes, len, &sigOff, &sigSize, &reason)) {
        detail[@"error"] = [NSString stringWithFormat:@"签名结构无效：%@", reason ?: @"找不到签名块"];
        return detail;
    }
    SBSignatureInfo info;
    if (!SBParseSignature(bytes, len, sigOff, sigSize, &info, &reason)) {
        detail[@"error"] = [NSString stringWithFormat:@"签名结构无效：%@", reason ?: @"解析 CodeDirectory 失败"];
        return detail;
    }
    detail[@"structureOK"] = @YES;
    // 0.2.14：LC 一致性——检查器与 dyld 都读 LC_CODE_SIGNATURE（见
    // SBFindSignature），没有“第二份读法”可核对；能核对的是 LC 给出的
    // 范围与 superblob 自身长度、CMS 槽是否落在 superblob 内。注意
    // superblob 长度小于 LC datasize 是正常的（Apple 与 codesign 的签名
    // 区尾部都有填充/空闲，0.2.14 原型实测：宿主 0x48e5 < 0x88d0、
    // Via 0x18058 < 0x1b580），不相等不是坏项。
    detail[@"lcDataOff"] = @(sigOff);
    detail[@"lcDataSize"] = @(sigSize);
    detail[@"superblobLength"] = @(info.superblobLength);
    BOOL lcOK = info.superblobLength > 0
        && info.superblobLength <= sigSize
        && (!info.hasSignatureSlot
            || (uint64_t)info.cmsOffset + 8 + (info.cmsBlobLength > 8 ? info.cmsBlobLength - 8 : 0) <= info.superblobLength);
    detail[@"lcSignatureOK"] = @(lcOK);
    if (!lcOK) {
        detail[@"error"] = @"LC_CODE_SIGNATURE 与 superblob 长度对不上，或 CMS 槽超出 superblob";
    }
    NSString *identifier = SBReadCDString(&info.cd, info.cd.identOffset);
    if (identifier.length > 0) {
        detail[@"identifier"] = identifier;
    } else {
        detail[@"error"] = @"CodeDirectory 没有 identifier";
    }
    NSString *teamID = SBReadCDString(&info.cd, info.cd.teamOffset);
    if (teamID.length > 0) {
        detail[@"teamID"] = teamID;
    }
    detail[@"hasCMS"] = @(info.hasSignatureSlot);
    if (!info.hasSignatureSlot) {
        detail[@"error"] = @"superblob 里没有 CMS 签名块";
    }
    detail[@"pageCount"] = @(info.cd.nCodeSlots);

    // 页哈希逐项验（与 validateSignature 同款；CMS 缺失也照验，
    // 各字段独立记，调用方在日志里分得清“CMS 缺失”和“页哈希不过”）。
    uint32_t firstBadPage = 0;
    BOOL pagesOK = SBVerifyCDPages(bytes, &info.cd, &firstBadPage, &reason);
    if (!pagesOK) {
        if (firstBadPage == UINT32_MAX) {
            detail[@"error"] = @"代码页超出 codeLimit";
        } else {
            detail[@"firstBadPage"] = @(firstBadPage);
            detail[@"error"] = [NSString stringWithFormat:@"第 %u 页内容哈希与签名里存的不一致，文件可能被改过", firstBadPage];
        }
    }
    detail[@"pageHashOK"] = @(pagesOK);

    // 0.2.12：CMS 逐项（可解析、链完整、叶子未过期、摘要与 CD 对得上）。
    // 0.2.14：再加 CMS 签名值密码学验签 + Apple 9.1/9.2 属性比对。
    SBCMSDetail cms;
    memset(&cms, 0, sizeof(cms));
    BOOL hasCMSDetail = NO;
    if (info.hasSignatureSlot) {
        SBInspectCMS(bytes + sigOff, sigSize, info.cmsOffset, info.cmsBlobLength,
                     &info.cd, info.hasAltCD ? &info.altCD : NULL, &cms);
        hasCMSDetail = YES;
        detail[@"cmsLength"] = @(cms.cmsDERLength);
        detail[@"cmsCertCount"] = @(cms.certCount);
        detail[@"cmsHasWWDR"] = @(cms.hasWWDR);
        detail[@"cmsChainComplete"] = @(cms.chainComplete);
        detail[@"cmsCDHashOK"] = @(cms.cdHashOK);
        detail[@"cmsLeafExpired"] = @(cms.leafExpired);
        detail[@"cmsSignatureValid"] = @(cms.signatureValid);
        detail[@"cmsAppleAttrsValid"] = @(cms.appleAttrsValid);
        if (cms.signatureError[0] != '\0') {
            detail[@"cmsSignatureError"] = [NSString stringWithUTF8String:cms.signatureError];
        }
        if (cms.appleAttrsError[0] != '\0') {
            detail[@"cmsAppleAttrsError"] = [NSString stringWithUTF8String:cms.appleAttrsError];
        }
        if (cms.leafCN[0] != '\0') {
            detail[@"cmsLeafCN"] = [NSString stringWithUTF8String:cms.leafCN];
        }
        if (cms.intermediateCN[0] != '\0') {
            detail[@"cmsIntermediateCN"] = [NSString stringWithUTF8String:cms.intermediateCN];
        }
        if (cms.leafExpiry[0] != '\0') {
            detail[@"cmsLeafExpiry"] = [NSString stringWithUTF8String:cms.leafExpiry];
        }
        if (cms.error[0] != '\0') {
            detail[@"cmsError"] = [NSString stringWithUTF8String:cms.error];
            if (detail[@"error"] == [NSNull null]) {
                detail[@"error"] = detail[@"cmsError"];
            }
        } else if (cms.leafExpired) {
            NSString *expired = [NSString stringWithFormat:@"叶子证书已过期（到期 %@）",
                                 [NSString stringWithUTF8String:cms.leafExpiry]];
            detail[@"cmsError"] = expired;
            if (detail[@"error"] == [NSNull null]) {
                detail[@"error"] = expired;
            }
        } else if (!cms.cdHashOK) {
            detail[@"cmsError"] = @"CMS 摘要与 CodeDirectory 对不上，签名后文件被改过";
            if (detail[@"error"] == [NSNull null]) {
                detail[@"error"] = detail[@"cmsError"];
            }
        } else if (!cms.signatureValid) {
            detail[@"cmsError"] = [NSString stringWithUTF8String:cms.signatureError];
            if (detail[@"error"] == [NSNull null]) {
                detail[@"error"] = detail[@"cmsError"];
            }
        } else if (!cms.appleAttrsValid) {
            detail[@"cmsError"] = [NSString stringWithUTF8String:cms.appleAttrsError];
            if (detail[@"error"] == [NSNull null]) {
                detail[@"error"] = detail[@"cmsError"];
            }
        }
    }

    // 备用 CodeDirectory（SHA-256，dyld 优先用）页哈希。
    BOOL altOK = YES;
    if (info.hasAltCD) {
        detail[@"hasAltCD"] = @YES;
        uint32_t altBadPage = 0;
        altOK = SBVerifyCDPages(bytes, &info.altCD, &altBadPage, &reason);
        if (!altOK) {
            if (altBadPage == UINT32_MAX) {
                detail[@"error"] = @"备用 CodeDirectory 代码页超出 codeLimit";
            } else {
                detail[@"altFirstBadPage"] = @(altBadPage);
                detail[@"error"] = [NSString stringWithFormat:@"备用 CodeDirectory 第 %u 页内容哈希与签名里存的不一致", altBadPage];
            }
        }
    }
    detail[@"altPageHashOK"] = @(altOK);

    // 特殊槽（entitlements 等）哈希。
    uint32_t badSlot = 0;
    BOOL specialOK = SBVerifySpecialSlots(bytes + sigOff, sigSize, &info, &info.cd, &badSlot);
    if (!specialOK) {
        detail[@"badSpecialSlot"] = @(badSlot);
        detail[@"error"] = [NSString stringWithFormat:@"特殊槽 %u 哈希与签名里存的不一致，签名后文件被改过", badSlot];
    }
    detail[@"specialSlotsOK"] = @(specialOK);

    BOOL cmsOK = hasCMSDetail
        && cms.cmsDERLength > 0
        && cms.parseOK
        && cms.chainComplete
        && !cms.leafExpired
        && cms.cdHashOK
        && cms.signatureValid
        && cms.appleAttrsValid
        && cms.error[0] == '\0';
    if (identifier.length > 0 && pagesOK && altOK && specialOK && cmsOK && lcOK) {
        detail[@"valid"] = @YES;
    }
    return detail;
}

@end
