// SBLCPatcher.m — 0.2.17：LiveContainer 打补丁器的接线层（我们自己的代码）。
//
// 打补丁本体是同目录 LiveContainer/LCMachOUtils.m（LiveContainer 原样代码，
// 见该文件头注）；这里只做 Swift 可调的薄包装：按 LCAppInfo.m:326-340 的
// 调用形状逐切片调 LCPatchExecSlice，并把结果翻译成调用方原来用的错误码。
// 两个小助手（SBMachOEntryOffset / SBMachOHasIDDylib）是旧 SBMachOPatcher.c
// 的复刻（同名同签名，调用点不用改），改用 LCParseMachO 做切片遍历。

#import "SBLCPatcher.h"

#import "LiveContainer/LCMachOUtils.h"

#import <fcntl.h>
#import <libkern/OSByteOrder.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <mach/machine.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

/// 有界遍历一个 64 位切片的加载命令：任何越界都停下（不报错，只停）。
/// filePtr 是整文件映射起点，fileSize 是文件总字节数（fd 上 fstat 得到）。
static void SBScanLoadCommands(struct mach_header_64 *header, void *filePtr, off_t fileSize,
                               void (^handler)(uint32_t cmd, void *cmdPtr, BOOL *stop)) {
    uint8_t *end = (uint8_t *)filePtr + fileSize;
    struct load_command *cmd = (struct load_command *)(header + 1);
    if ((uint8_t *)cmd + sizeof(struct load_command) > end) {
        return;
    }
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if ((uint8_t *)cmd + sizeof(struct load_command) > end) {
            return;
        }
        if (cmd->cmdsize < sizeof(struct load_command)) {
            return;
        }
        if ((uint8_t *)cmd + cmd->cmdsize > end) {
            return;
        }
        BOOL stop = NO;
        handler(cmd->cmd, cmd, &stop);
        if (stop) {
            return;
        }
        cmd = (struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
    }
}

/// 预扫 fat 头：LCParseMachO 的 fat 分支只对 arm64/arm 切片调回调，
/// x86_64 切片到不了回调；fat 包里没有 arm64 切片时靠预扫区分
/// “32 位”与“非 arm64 架构”。thin 文件不走这里（三个标志全 NO）。
static void SBFatArchKind(const char *path, BOOL *hasARM64, BOOL *hasARM32, BOOL *hasOther) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return;
    }
    uint32_t magic = 0;
    ssize_t n = read(fd, &magic, sizeof(magic));
    if (n != (ssize_t)sizeof(magic) || magic != FAT_CIGAM) {
        close(fd);
        return;
    }
    struct fat_header fatHeader;
    lseek(fd, 0, SEEK_SET);
    if (read(fd, &fatHeader, sizeof(fatHeader)) != (ssize_t)sizeof(fatHeader)) {
        close(fd);
        return;
    }
    uint32_t archCount = OSSwapBigToHostInt32(fatHeader.nfat_arch);
    if (archCount > 64) {
        close(fd);
        return;
    }
    for (uint32_t i = 0; i < archCount; i++) {
        struct fat_arch arch;
        if (read(fd, &arch, sizeof(arch)) != (ssize_t)sizeof(arch)) {
            break;
        }
        uint32_t cputype = OSSwapBigToHostInt32(arch.cputype);
        if (cputype == CPU_TYPE_ARM64) {
            *hasARM64 = YES;
        } else if (cputype == CPU_TYPE_ARM) {
            *hasARM32 = YES;
        } else {
            *hasOther = YES;
        }
    }
    close(fd);
}

int32_t SBLCPatchExecutable(const char *path, int doInject, int *seg_mismatch_out) {
    if (seg_mismatch_out) {
        *seg_mismatch_out = 0;
    }
    // fat 包里没有 arm64 切片：不用打补丁，直接按架构报错。
    BOOL fatHasARM64 = NO, fatHasARM32 = NO, fatHasOther = NO;
    SBFatArchKind(path, &fatHasARM64, &fatHasARM32, &fatHasOther);
    if (!fatHasARM64 && (fatHasARM32 || fatHasOther)) {
        return fatHasARM32 ? SB_LC_PATCH_ERR_UNSUPPORTED_32BIT
                           : SB_LC_PATCH_ERR_UNSUPPORTED_ARCH;
    }

    __block int32_t result = SB_LC_PATCH_OK;
    __block BOOL sawARM64 = NO;
    __block BOOL saw32Bit = NO;
    __block BOOL sawOtherArch = NO;
    NSString *parseError = LCParseMachO(path, false, ^(const char *slicePath, struct mach_header_64 *header, int fd, void *filePtr) {
        (void)fd;
        (void)filePtr;
        if (header->cputype != CPU_TYPE_ARM64) {
            if (header->cputype == CPU_TYPE_ARM) {
                saw32Bit = YES;
            } else {
                sawOtherArch = YES;
            }
            return;
        }
        sawARM64 = YES;
        // 加密包在任何修改前拒绝（LCAppInfo.m:340-342 同款）。
        if (LCIsMachOEncrypted(header)) {
            result = SB_LC_PATCH_ERR_ENCRYPTED;
            return;
        }
        int patchResult = LCPatchExecSlice(slicePath, header, (bool)doInject);
        if (patchResult & PATCH_EXEC_RESULT_SEG_COUNT_MISMATCH) {
            if (seg_mismatch_out) {
                *seg_mismatch_out = 1;
            }
        }
        if (patchResult & PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER) {
            result = SB_LC_PATCH_ERR_NO_SPACE;
        }
    });
    if (parseError) {
        if ([parseError hasPrefix:@"Not a Mach-O"]) {
            return SB_LC_PATCH_ERR_NOT_MACHO;
        }
        return SB_LC_PATCH_ERR_IO;
    }
    if (result != SB_LC_PATCH_OK) {
        return result;
    }
    if (!sawARM64) {
        if (saw32Bit) {
            return SB_LC_PATCH_ERR_UNSUPPORTED_32BIT;
        }
        if (sawOtherArch) {
            return SB_LC_PATCH_ERR_UNSUPPORTED_ARCH;
        }
        return SB_LC_PATCH_ERR_NOT_MACHO;
    }
    return SB_LC_PATCH_OK;
}

// MARK: - 0.2.44 B-2 整包命名空间改写

static uint32_t SBRnd32(uint32_t v, uint32_t r) {
    r--;
    return (v + r) & ~r;
}

/// 与 LCMachOUtils.m 的 SBGuestDjb2 同算法（djb2，低 24 位）——两处须
/// 一致：短名由打补丁器写、由 Swift 侧 SBInstaller.djb2Hex6 验。
static void SBGuestShortInstallName(const char *bundleID, char *buf, size_t bufSize) {
    uint64_t h = 5381;
    for (const unsigned char *p = (const unsigned char *)bundleID; *p; p++) {
        h = h * 33 + *p;
    }
    snprintf(buf, bufSize, "%06llx", (unsigned long long)(h & 0xffffff));
}

/// 改写一条 dylib 命令的名字。返回 1=已改写，0=改不了（原样留着）。
/// 新串塞得进原名域就地写；塞不进且命令表后有空闲就扩命令、后移命令表。
static int SBRewriteDylibName(struct mach_header_64 *header,
                              struct dylib_command *dylibCmd,
                              const char *newName,
                              uint32_t *freeBytes) {
    uint32_t nameOffset = dylibCmd->dylib.name.offset;
    if (nameOffset >= dylibCmd->cmdsize) {
        return 0;
    }
    uint32_t oldCap = dylibCmd->cmdsize - nameOffset;
    size_t newLen = strlen(newName) + 1;
    if (newLen <= oldCap) {
        memset((uint8_t *)dylibCmd + nameOffset, 0, oldCap);
        memcpy((uint8_t *)dylibCmd + nameOffset, newName, newLen);
        return 1;
    }
    uint32_t newCmdSize = (uint32_t)sizeof(struct dylib_command) + SBRnd32((uint32_t)newLen, 8);
    uint32_t delta = newCmdSize - dylibCmd->cmdsize;
    if (delta > *freeBytes) {
        return 0;
    }
    uint8_t *cmdsEnd = (uint8_t *)header + sizeof(struct mach_header_64) + header->sizeofcmds;
    uint8_t *afterCmd = (uint8_t *)dylibCmd + dylibCmd->cmdsize;
    memmove(afterCmd + delta, afterCmd, (size_t)(cmdsEnd - afterCmd));
    dylibCmd->cmdsize = newCmdSize;
    header->sizeofcmds += delta;
    *freeBytes -= delta;
    memset((uint8_t *)dylibCmd + nameOffset, 0, newCmdSize - nameOffset);
    memcpy((uint8_t *)dylibCmd + nameOffset, newName, newLen);
    return 1;
}

/// 有界比较一条 dylib 命令里的名字（名串理论上可能无 NUL 结尾越过命令
/// 边界——按名域长度截断再比，不越界读）。
static BOOL SBNameEquals(struct dylib_command *dylib, const char *expected) {
    uint32_t nameOffset = dylib->dylib.name.offset;
    if (nameOffset >= dylib->cmdsize) {
        return NO;
    }
    const char *cur = (const char *)dylib + nameOffset;
    size_t maxLen = dylib->cmdsize - nameOffset;
    size_t curLen = strnlen(cur, maxLen);
    size_t expLen = strlen(expected);
    return curLen == expLen && memcmp(cur, expected, expLen) == 0;
}

/// 本切片命令表后、__text 前的空闲字节数（扩命令的上限）；找不到 __text
/// 时返回 0（只允许就地写）。
static uint32_t SBTextFreeBytes(struct mach_header_64 *header, void *filePtr, off_t fileSize) {
    __block uint32_t textOff = 0;
    SBScanLoadCommands(header, filePtr, fileSize, ^(uint32_t cmd, void *cmdPtr, BOOL *stop) {
        if (cmd != LC_SEGMENT_64) {
            return;
        }
        struct segment_command_64 *seg = (struct segment_command_64 *)cmdPtr;
        if (strcmp(seg->segname, "__TEXT") != 0) {
            return;
        }
        struct section_64 *sect = (struct section_64 *)((uint8_t *)cmdPtr + sizeof(struct segment_command_64));
        for (uint32_t i = 0; i < seg->nsects; i++) {
            if (strcmp(sect[i].sectname, "__text") == 0) {
                textOff = sect[i].offset;
                *stop = YES;
                return;
            }
        }
    });
    uint32_t cmdsEnd = (uint32_t)sizeof(struct mach_header_64) + header->sizeofcmds;
    return (textOff > cmdsEnd) ? (textOff - cmdsEnd) : 0;
}

int32_t SBLCPatchExecutableForGuest(const char *path, int doInject, int *seg_mismatch_out,
                                    const char *bundleID) {
    LCSetPatchGuestBundleID(bundleID);
    int32_t result = SBLCPatchExecutable(path, doInject, seg_mismatch_out);
    LCSetPatchGuestBundleID(NULL);
    return result;
}

int SBMachOIDDylibName(const char *path, char *nameOut, size_t nameOutSize) {
    if (!nameOut || nameOutSize == 0) {
        return 0;
    }
    nameOut[0] = '\0';
    __block int found = 0;
    NSString *error = LCParseMachO(path, true, ^(const char *slicePath, struct mach_header_64 *header, int fd, void *filePtr) {
        (void)slicePath;
        if (found || header->cputype != CPU_TYPE_ARM64) {
            return;
        }
        struct stat st;
        off_t fileSize = (fstat(fd, &st) == 0) ? st.st_size : 0;
        if (fileSize <= 0) {
            return;
        }
        SBScanLoadCommands(header, filePtr, fileSize, ^(uint32_t cmd, void *cmdPtr, BOOL *stop) {
            if (cmd != LC_ID_DYLIB) {
                return;
            }
            struct dylib_command *dylib = (struct dylib_command *)cmdPtr;
            const char *name = (const char *)dylib + dylib->dylib.name.offset;
            size_t maxLen = (size_t)((uint8_t *)filePtr + fileSize - (uint8_t *)name);
            size_t len = strnlen(name, maxLen);
            if (len >= nameOutSize) {
                len = nameOutSize - 1;
            }
            memcpy(nameOut, name, len);
            nameOut[len] = '\0';
            found = 1;
            *stop = YES;
        });
    });
    if (error) {
        return 0;
    }
    return found;
}

int SBLCPatchBundleNamespace(const char *bundlePath, const char *execPath,
                             const char *bundleID, int *warningsOut) {
    if (warningsOut) {
        *warningsOut = 0;
    }
    if (!bundlePath || !execPath || !bundleID || bundleID[0] == '\0') {
        return -1;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundlePathStr = [NSString stringWithUTF8String:bundlePath];
    NSString *frameworksDir = [bundlePathStr stringByAppendingPathComponent:@"Frameworks"];
    // framework 名 → 唯一安装名（@rpath/<bundleID>/<Fw>.framework/<Fw>）。
    NSMutableArray<NSDictionary *> *frameworks = [NSMutableArray array];
    NSArray<NSString *> *fwEntries = [fm contentsOfDirectoryAtPath:frameworksDir error:nil];
    if (fwEntries) {
        for (NSString *entry in fwEntries) {
            if (![entry hasSuffix:@".framework"]) {
                continue;
            }
            NSString *fwDir = [frameworksDir stringByAppendingPathComponent:entry];
            NSString *fwName = [entry stringByDeletingPathExtension];
            NSString *execName = fwName;
            NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:
                [fwDir stringByAppendingPathComponent:@"Info.plist"]];
            if ([infoPlist[@"CFBundleExecutable"] isKindOfClass:[NSString class]] &&
                [(NSString *)infoPlist[@"CFBundleExecutable"] length] > 0) {
                execName = infoPlist[@"CFBundleExecutable"];
            }
            NSString *binaryPath = [fwDir stringByAppendingPathComponent:execName];
            if (![fm fileExistsAtPath:binaryPath]) {
                continue;
            }
            NSString *uniqueID = [NSString stringWithFormat:@"@rpath/%s/%@.framework/%@",
                                  bundleID, fwName, execName];
            [frameworks addObject:@{ @"name": fwName, @"execName": execName,
                                     @"binaryPath": binaryPath, @"uniqueID": uniqueID }];
        }
    }
    // 待处理文件：主程序（唯一名 "<bundleID>/<basename>"）＋各 framework。
    NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
    NSString *execBase = [[NSString stringWithUTF8String:execPath] lastPathComponent];
    [files addObject:@{ @"path": [NSString stringWithUTF8String:execPath],
                        @"uniqueID": [NSString stringWithFormat:@"%s/%@", bundleID, execBase],
                        @"isMain": @YES }];
    for (NSDictionary *fw in frameworks) {
        [files addObject:@{ @"path": fw[@"binaryPath"], @"uniqueID": fw[@"uniqueID"], @"isMain": @NO }];
    }
    __block int filesChanged = 0;
    __block int warnings = 0;
    for (NSDictionary *file in files) {
        NSString *filePath = file[@"path"];
        NSString *uniqueID = file[@"uniqueID"];
        BOOL isMain = [file[@"isMain"] boolValue];
        const char *filePathC = [filePath fileSystemRepresentation];
        __block BOOL changed = NO;
        NSString *parseError = LCParseMachO(filePathC, false, ^(const char *slicePath, struct mach_header_64 *header, int fd, void *filePtr) {
            (void)slicePath;
            if (header->cputype != CPU_TYPE_ARM64) {
                return;
            }
            if (LCIsMachOEncrypted(header)) {
                return; // 加密文件不动（主程序加密时安装早已拒绝）。
            }
            struct stat st;
            off_t fileSize = (fstat(fd, &st) == 0) ? st.st_size : 0;
            if (fileSize <= 0) {
                return;
            }
            uint32_t freeBytes = SBTextFreeBytes(header, filePtr, fileSize);
            uint32_t off = (uint32_t)sizeof(struct mach_header_64);
            for (uint32_t i = 0; i < header->ncmds; i++) {
                struct load_command *lc = (struct load_command *)((uint8_t *)header + off);
                if (off + sizeof(struct load_command) > (uint32_t)fileSize ||
                    lc->cmdsize < sizeof(struct load_command) ||
                    off + lc->cmdsize > (uint32_t)fileSize) {
                    break;
                }
                if (lc->cmd == LC_ID_DYLIB) {
                    struct dylib_command *dylib = (struct dylib_command *)lc;
                    if (!SBNameEquals(dylib, [uniqueID UTF8String])) {
                        int ok = SBRewriteDylibName(header, dylib, [uniqueID UTF8String], &freeBytes);
                        if (!ok && isMain) {
                            // 主程序 ID 实在写不进完整唯一名（dylinker 复用路无
                            // 空闲）：退到 6 位短名就地写（名域 >= 7 字节即可），
                            // 仍是每客唯一；写不进时才记警告、原样留着。
                            char shortBuf[8];
                            SBGuestShortInstallName(bundleID, shortBuf, sizeof(shortBuf));
                            uint32_t nameOffset = dylib->dylib.name.offset;
                            if (dylib->cmdsize - nameOffset >= 7) {
                                memset((uint8_t *)dylib + nameOffset, 0, dylib->cmdsize - nameOffset);
                                memcpy((uint8_t *)dylib + nameOffset, shortBuf, strlen(shortBuf) + 1);
                                ok = 1;
                            }
                        }
                        if (ok) {
                            changed = YES;
                        } else {
                            warnings++;
                            fprintf(stderr, "[SB] namespace: cannot rewrite LC_ID_DYLIB in %s (no room)\n", filePathC);
                        }
                    }
                }
                // 0.2.45：引用分支已删——LC_LOAD_DYLIB／WEAK／REEXPORT 的
                // @rpath 引用是路径模板，绝不能改写。0.2.44 在这里把引用改
                // 成 @rpath/<bundleID>/<Fw>.framework/<Fw>，却既没在磁盘上
                // 建 Frameworks/<bundleID>/ 子目录、没移动任何 framework
                // 文件，也没加任何 LC_RPATH，dyld 按未变的 LC_RPATH 展开后
                // 找不到文件，4 个客当场 dlopen 失败（Library not loaded；
                // 离线实证：OmoFun 改写前 35/35 引用可解析，改写后 0/35）。
                // 去重只靠 LC_ID_DYLIB：引用保持 @rpath/<Fw>.framework/<Fw>
                // 就能从磁盘正确加载；另一客引用同一 framework 名时，dyld
                // 按安装名查不到本客的唯一 ID，便按自己的路径加载，不串味。
                // （改不了留原样的退路随分支一起删——引用不再改写，无警告可记。）
                off += lc->cmdsize;
            }
        });
        if (parseError) {
            continue; // 非 Mach-O 文件跳过。
        }
        if (changed) {
            filesChanged++;
        }
    }
    if (warningsOut) {
        *warningsOut = warnings;
    }
    return filesChanged;
}

// MARK: - 0.2.45：rev 4 损坏的逆向修复与离线断言

/// 列出命名空间改写触碰的文件：主程序＋ Frameworks/*.framework 的可执行
/// 文件（Info.plist CFBundleExecutable 为准）。与 SBLCPatchBundleNamespace
/// 的枚举同款，供逆向修复与引用校验共用。
static NSArray<NSString *> *SBGuestNamespaceBinaryPaths(const char *bundlePath, const char *execPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundlePathStr = [NSString stringWithUTF8String:bundlePath];
    NSString *frameworksDir = [bundlePathStr stringByAppendingPathComponent:@"Frameworks"];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    [paths addObject:[NSString stringWithUTF8String:execPath]];
    NSArray<NSString *> *fwEntries = [fm contentsOfDirectoryAtPath:frameworksDir error:nil];
    if (fwEntries) {
        for (NSString *entry in fwEntries) {
            if (![entry hasSuffix:@".framework"]) {
                continue;
            }
            NSString *fwDir = [frameworksDir stringByAppendingPathComponent:entry];
            NSString *fwName = [entry stringByDeletingPathExtension];
            NSString *execName = fwName;
            NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:
                [fwDir stringByAppendingPathComponent:@"Info.plist"]];
            if ([infoPlist[@"CFBundleExecutable"] isKindOfClass:[NSString class]] &&
                [(NSString *)infoPlist[@"CFBundleExecutable"] length] > 0) {
                execName = infoPlist[@"CFBundleExecutable"];
            }
            NSString *binaryPath = [fwDir stringByAppendingPathComponent:execName];
            if ([fm fileExistsAtPath:binaryPath]) {
                [paths addObject:binaryPath];
            }
        }
    }
    return paths;
}

/// 一条 dylib 命令的名字是否以 "@rpath/<bundleID>/" 开头（rev 4 损坏的
/// 直接指纹）。nameBuf 须是按名域长度截断的 NUL 结尾串。
static BOOL SBNameHasBundleIDPrefix(const char *nameBuf, const char *bundleID) {
    if (strncmp(nameBuf, "@rpath/", 7) != 0) {
        return NO;
    }
    size_t bidLen = strlen(bundleID);
    if (strncmp(nameBuf + 7, bundleID, bidLen) != 0) {
        return NO;
    }
    return nameBuf[7 + bidLen] == '/';
}

/// 把 "@rpath/<bundleID>/<Fw>.framework/<Exec>" 还原成
/// "@rpath/<Fw>.framework/<Exec>"。 remainder 须形如
/// "<Fw>.framework/<Exec>"（Fw 不含 '/'，Exec 非空），否则返回 NO。
static BOOL SBRev4RestoredName(const char *nameBuf, const char *bundleID,
                               char *outBuf, size_t outBufSize) {
    size_t prefixLen = 7 + strlen(bundleID) + 1; // "@rpath/" + bundleID + "/"
    const char *rest = nameBuf + prefixLen;
    const char *fwSuffix = strstr(rest, ".framework/");
    if (!fwSuffix || fwSuffix == rest) {
        return NO;
    }
    for (const char *p = rest; p < fwSuffix; p++) {
        if (*p == '/') {
            return NO;
        }
    }
    const char *execPart = fwSuffix + strlen(".framework/");
    if (execPart[0] == '\0') {
        return NO;
    }
    size_t need = strlen("@rpath/") + strlen(rest) + 1;
    if (need > outBufSize) {
        return NO;
    }
    snprintf(outBuf, outBufSize, "@rpath/%s", rest);
    return YES;
}

/// 逆向修复 rev 4 的引用改写（0.2.45）：把包内主程序＋全部 framework 二
/// 进制里所有 "@rpath/<bundleID>/<Fw>.framework/<Fw>" 形式的
/// LC_LOAD_DYLIB／WEAK／REEXPORT 引用改回 "@rpath/<Fw>.framework/<Fw>"。
/// framework 的 LC_ID_DYLIB 保持唯一名不动（那是修法 A 要的终态）。
/// 逆向只缩短字符串：新串一定塞得进已扩容的命令名域，走就地写分支。
/// 调用顺序关键：先跑修正后的 SBLCPatchBundleNamespace（只改 ID），再跑
/// 本函数——绝不能反过来（旧版引用改写会把刚还原的引用再打坏）。
/// - Returns: 改写过的文件数；<0 表示致命 I/O 错误（包目录读不出）。
int SBLCRepairRev4Namespace(const char *bundlePath, const char *execPath,
                            const char *bundleID, int *warningsOut) {
    if (warningsOut) {
        *warningsOut = 0;
    }
    if (!bundlePath || !execPath || !bundleID || bundleID[0] == '\0') {
        return -1;
    }
    NSArray<NSString *> *paths = SBGuestNamespaceBinaryPaths(bundlePath, execPath);
    __block int filesChanged = 0;
    __block int warnings = 0;
    for (NSString *filePath in paths) {
        const char *filePathC = [filePath fileSystemRepresentation];
        __block BOOL changed = NO;
        NSString *parseError = LCParseMachO(filePathC, false, ^(const char *slicePath, struct mach_header_64 *header, int fd, void *filePtr) {
            (void)slicePath;
            if (header->cputype != CPU_TYPE_ARM64) {
                return;
            }
            if (LCIsMachOEncrypted(header)) {
                return;
            }
            struct stat st;
            off_t fileSize = (fstat(fd, &st) == 0) ? st.st_size : 0;
            if (fileSize <= 0) {
                return;
            }
            uint32_t freeBytes = SBTextFreeBytes(header, filePtr, fileSize);
            uint32_t off = (uint32_t)sizeof(struct mach_header_64);
            for (uint32_t i = 0; i < header->ncmds; i++) {
                struct load_command *lc = (struct load_command *)((uint8_t *)header + off);
                if (off + sizeof(struct load_command) > (uint32_t)fileSize ||
                    lc->cmdsize < sizeof(struct load_command) ||
                    off + lc->cmdsize > (uint32_t)fileSize) {
                    break;
                }
                if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB ||
                    lc->cmd == LC_REEXPORT_DYLIB) {
                    struct dylib_command *dylib = (struct dylib_command *)lc;
                    uint32_t nameOffset = dylib->dylib.name.offset;
                    if (nameOffset >= dylib->cmdsize) {
                        off += lc->cmdsize;
                        continue;
                    }
                    size_t maxLen = dylib->cmdsize - nameOffset;
                    char curName[512];
                    size_t curLen = strnlen((const char *)dylib + nameOffset, maxLen);
                    if (curLen >= sizeof(curName)) {
                        off += lc->cmdsize;
                        continue;
                    }
                    memcpy(curName, (const char *)dylib + nameOffset, curLen);
                    curName[curLen] = '\0';
                    if (SBNameHasBundleIDPrefix(curName, bundleID)) {
                        char restored[512];
                        if (SBRev4RestoredName(curName, bundleID, restored, sizeof(restored))) {
                            if (SBRewriteDylibName(header, dylib, restored, &freeBytes)) {
                                changed = YES;
                            } else {
                                // 理论上到不了：还原只缩短，新串必能就地写。
                                warnings++;
                                fprintf(stderr, "[SB] repair-rev4: cannot restore reference %s in %s\n",
                                        curName, filePathC);
                            }
                        }
                    }
                }
                off += lc->cmdsize;
            }
        });
        if (parseError) {
            continue;
        }
        if (changed) {
            filesChanged++;
        }
    }
    if (warningsOut) {
        *warningsOut = warnings;
    }
    return filesChanged;
}

/// rev 4 损坏的直接指纹：主程序是否仍有含 "@rpath/<bundleID>/" 前缀的
/// framework 引用。有则返回 1（须走重打补丁＋逆向修复），否则返回 0。
/// 读不到主程序／不是 Mach-O／没有 arm64 切片时返回 0（不以此为由触发）。
int SBLCNamespaceNeedsRepair(const char *execPath, const char *bundleID) {
    if (!execPath || !bundleID || bundleID[0] == '\0') {
        return 0;
    }
    __block int found = 0;
    NSString *error = LCParseMachO(execPath, true, ^(const char *slicePath, struct mach_header_64 *header, int fd, void *filePtr) {
        (void)slicePath;
        if (found || header->cputype != CPU_TYPE_ARM64) {
            return;
        }
        struct stat st;
        off_t fileSize = (fstat(fd, &st) == 0) ? st.st_size : 0;
        if (fileSize <= 0) {
            return;
        }
        SBScanLoadCommands(header, filePtr, fileSize, ^(uint32_t cmd, void *cmdPtr, BOOL *stop) {
            if (cmd != LC_LOAD_DYLIB && cmd != LC_LOAD_WEAK_DYLIB && cmd != LC_REEXPORT_DYLIB) {
                return;
            }
            struct dylib_command *dylib = (struct dylib_command *)cmdPtr;
            uint32_t nameOffset = dylib->dylib.name.offset;
            if (nameOffset >= dylib->cmdsize) {
                return;
            }
            size_t maxLen = dylib->cmdsize - nameOffset;
            char curName[512];
            size_t curLen = strnlen((const char *)dylib + nameOffset, maxLen);
            if (curLen >= sizeof(curName)) {
                return;
            }
            memcpy(curName, (const char *)dylib + nameOffset, curLen);
            curName[curLen] = '\0';
            if (SBNameHasBundleIDPrefix(curName, bundleID)) {
                found = 1;
                *stop = YES;
            }
        });
    });
    if (error) {
        return 0;
    }
    return found;
}

/// 展开一条 @rpath 引用：按引用文件的 LC_RPATH 列表逐条展开，
/// @executable_path → .app 包目录，@loader_path → 引用文件所在目录，
/// 其余原样作前缀；任一展开在磁盘上存在即返回 YES。
/// 关键 dyld 语义：解析某 framework 的引用时，dyld 除了用该 framework
/// 自己的 LC_RPATH，还会用主程序的 LC_RPATH 兜底（0.2.43 实证：OmoFun
/// 的 Ass.framework 自己的 LC_RPATH 只有编译机 /nix/store 路径，Ass →
/// Freetype 的引用全靠主程序的 @executable_path/Frameworks 才解析到）。
/// 所以调用方须把主程序的 LC_RPATH 也传进来（mainRpaths），只用引用文件
/// 自己的 LC_RPATH 会把 0.2.43 时能打开的包误判为坏包。
static BOOL SBRefResolvesInBundle(NSString *ref, NSArray<NSString *> *rpaths,
                                  NSArray<NSString *> *mainRpaths,
                                  NSString *bundlePath, NSString *fileDir) {
    if (![ref hasPrefix:@"@rpath/"]) {
        return YES; // 非 @rpath 引用不在本断言的检查范围。
    }
    NSString *remainder = [ref substringFromIndex:7];
    NSMutableArray<NSString *> *allRpaths = [NSMutableArray arrayWithArray:rpaths];
    for (NSString *mainRpath in mainRpaths) {
        if (![allRpaths containsObject:mainRpath]) {
            [allRpaths addObject:mainRpath];
        }
    }
    for (NSString *rpath in allRpaths) {
        NSString *base = rpath;
        base = [base stringByReplacingOccurrencesOfString:@"@executable_path" withString:bundlePath];
        base = [base stringByReplacingOccurrencesOfString:@"@loader_path" withString:fileDir];
        NSString *candidate;
        if ([base hasSuffix:@"/"]) {
            candidate = [base stringByAppendingString:remainder];
        } else {
            candidate = [base stringByAppendingFormat:@"/%@", remainder];
        }
        if (access([candidate fileSystemRepresentation], F_OK) == 0) {
            return YES;
        }
    }
    return NO;
}

/// 离线断言（0.2.45）：改写后逐条 framework 引用按 LC_RPATH 展开必须在
/// 包内存在，否则返回未解析条数（调用方拒绝安装／重打补丁）。
/// 只查 "@rpath/<Fw>.framework/<Fw>" 形式的引用（0.2.44 的损坏类）；
/// @rpath/*.dylib 系统库引用（libswift 等）不在包内，不查。
/// LC_LOAD／REEXPORT 严格查；WEAK 只在引用的 framework 本就随包发
/// 布时查（弱引用缺件是 dyld 容忍的合法情形，不因此拒装）。
/// 展开用引用文件自己的 LC_RPATH ＋主程序的 LC_RPATH（dyld 解析 framework
/// 引用时主程序 LC_RPATH 也兜底；只用引用文件自己的会把 0.2.43 能开的包误判）。
/// - Parameters:
///   - firstBadOut: 可为 NULL；非 NULL 时写首条未解析引用的原串。
/// - Returns: 未解析的引用条数；0 = 全过；<0 表示致命 I/O 错误。
int SBLCVerifyFrameworkReferences(const char *bundlePath, const char *execPath,
                                  char *firstBadOut, size_t firstBadOutSize) {
    if (firstBadOut && firstBadOutSize > 0) {
        firstBadOut[0] = '\0';
    }
    if (!bundlePath || !execPath) {
        return -1;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundlePathStr = [NSString stringWithUTF8String:bundlePath];
    NSString *frameworksDir = [bundlePathStr stringByAppendingPathComponent:@"Frameworks"];
    NSMutableSet<NSString *> *shippedFrameworks = [NSMutableSet set];
    NSArray<NSString *> *fwEntries = [fm contentsOfDirectoryAtPath:frameworksDir error:nil];
    if (fwEntries) {
        for (NSString *entry in fwEntries) {
            if ([entry hasSuffix:@".framework"]) {
                [shippedFrameworks addObject:[entry stringByDeletingPathExtension]];
            }
        }
    }
    NSArray<NSString *> *paths = SBGuestNamespaceBinaryPaths(bundlePath, execPath);
    __block int unresolved = 0;
    __block int ioError = 0;
    // 主程序的 LC_RPATH：dyld 解析 framework 引用时也会用它兜底
    //（见 SBRefResolvesInBundle），先一次读出。
    __block NSMutableArray<NSString *> *mainRpaths = [NSMutableArray array];
    NSString *mainParseError = LCParseMachO(execPath, true, ^(const char *slicePath, struct mach_header_64 *header, int fd, void *filePtr) {
        (void)slicePath;
        if (header->cputype != CPU_TYPE_ARM64) {
            return;
        }
        struct stat st;
        off_t fileSize = (fstat(fd, &st) == 0) ? st.st_size : 0;
        if (fileSize <= 0) {
            return;
        }
        SBScanLoadCommands(header, filePtr, fileSize, ^(uint32_t cmd, void *cmdPtr, BOOL *stop) {
            (void)stop;
            if (cmd != LC_RPATH) {
                return;
            }
            struct rpath_command *rpathCmd = (struct rpath_command *)cmdPtr;
            uint32_t pathOffset = rpathCmd->path.offset;
            if (pathOffset < rpathCmd->cmdsize) {
                const char *raw = (const char *)rpathCmd + pathOffset;
                size_t maxLen = rpathCmd->cmdsize - pathOffset;
                size_t len = strnlen(raw, maxLen);
                if (len > 0) {
                    NSString *rpathStr = [[NSString alloc] initWithBytes:raw length:len encoding:NSUTF8StringEncoding];
                    if (rpathStr) {
                        [mainRpaths addObject:rpathStr];
                    }
                }
            }
        });
    });
    if (mainParseError) {
        ioError = 1;
    }
    for (NSString *filePath in paths) {
        const char *filePathC = [filePath fileSystemRepresentation];
        NSString *fileDir = [filePath stringByDeletingLastPathComponent];
        NSString *parseError = LCParseMachO(filePathC, true, ^(const char *slicePath, struct mach_header_64 *header, int fd, void *filePtr) {
            (void)slicePath;
            if (header->cputype != CPU_TYPE_ARM64) {
                return;
            }
            struct stat st;
            off_t fileSize = (fstat(fd, &st) == 0) ? st.st_size : 0;
            if (fileSize <= 0) {
                ioError = 1;
                return;
            }
            __block NSMutableArray<NSString *> *rpaths = [NSMutableArray array];
            __block NSMutableArray<NSDictionary *> *refs = [NSMutableArray array];
            SBScanLoadCommands(header, filePtr, fileSize, ^(uint32_t cmd, void *cmdPtr, BOOL *stop) {
                (void)stop;
                if (cmd == LC_RPATH) {
                    struct rpath_command *rpathCmd = (struct rpath_command *)cmdPtr;
                    uint32_t pathOffset = rpathCmd->path.offset;
                    if (pathOffset < rpathCmd->cmdsize) {
                        const char *raw = (const char *)rpathCmd + pathOffset;
                        size_t maxLen = rpathCmd->cmdsize - pathOffset;
                        size_t len = strnlen(raw, maxLen);
                        if (len > 0) {
                            NSString *rpathStr = [[NSString alloc] initWithBytes:raw length:len encoding:NSUTF8StringEncoding];
                            if (rpathStr) {
                                [rpaths addObject:rpathStr];
                            }
                        }
                    }
                    return;
                }
                if (cmd != LC_LOAD_DYLIB && cmd != LC_LOAD_WEAK_DYLIB && cmd != LC_REEXPORT_DYLIB) {
                    return;
                }
                struct dylib_command *dylib = (struct dylib_command *)cmdPtr;
                uint32_t nameOffset = dylib->dylib.name.offset;
                if (nameOffset >= dylib->cmdsize) {
                    return;
                }
                size_t maxLen = dylib->cmdsize - nameOffset;
                size_t len = strnlen((const char *)dylib + nameOffset, maxLen);
                if (len == 0 || len >= 512) {
                    return;
                }
                char nameBuf[512];
                memcpy(nameBuf, (const char *)dylib + nameOffset, len);
                nameBuf[len] = '\0';
                NSString *ref = [NSString stringWithUTF8String:nameBuf];
                if (!ref || ![ref hasPrefix:@"@rpath/"]) {
                    return;
                }
                // 只查 framework 引用：须含 ".framework/"。
                if ([ref rangeOfString:@".framework/"].location == NSNotFound) {
                    return;
                }
                [refs addObject:@{ @"ref": ref, @"weak": @(cmd == LC_LOAD_WEAK_DYLIB) }];
            });
            for (NSDictionary *entry in refs) {
                NSString *ref = entry[@"ref"];
                BOOL isWeak = [entry[@"weak"] boolValue];
                if (isWeak) {
                    // 弱引用：只在引用的 framework 随包发布时才要求可解析。
                    NSString *afterRpath = [ref substringFromIndex:7];
                    NSRange fwRange = [afterRpath rangeOfString:@".framework/"];
                    NSString *fwName = (fwRange.location == NSNotFound)
                        ? afterRpath
                        : [afterRpath substringToIndex:fwRange.location];
                    // rev 4 损坏形 "@rpath/<bundleID>/<Fw>.framework/…" 里
                    // framework 名是最后一段，去掉 bundleID 前缀再取。
                    NSRange slash = [fwName rangeOfString:@"/" options:NSBackwardsSearch];
                    if (slash.location != NSNotFound) {
                        fwName = [fwName substringFromIndex:slash.location + 1];
                    }
                    if (![shippedFrameworks containsObject:fwName]) {
                        continue;
                    }
                }
                if (!SBRefResolvesInBundle(ref, rpaths, mainRpaths, bundlePathStr, fileDir)) {
                    unresolved++;
                    if (firstBadOut && firstBadOutSize > 0 && firstBadOut[0] == '\0') {
                        snprintf(firstBadOut, firstBadOutSize, "%s", [ref UTF8String]);
                    }
                }
            }
        });
        if (parseError) {
            ioError = 1;
        }
    }
    if (ioError && unresolved == 0) {
        return -1;
    }
    return unresolved;
}

int SBMachOEntryOffset(const char *path, uint64_t *entryoffOut) {
    if (entryoffOut) {
        *entryoffOut = 0;
    }
    __block uint64_t arm64eEntry = 0;
    __block BOOL hasARM64e = NO;
    __block uint64_t arm64Entry = 0;
    __block BOOL hasARM64 = NO;
    NSString *error = LCParseMachO(path, true, ^(const char *slicePath, struct mach_header_64 *header, int fd, void *filePtr) {
        (void)slicePath;
        if (header->cputype != CPU_TYPE_ARM64) {
            return;
        }
        struct stat st;
        off_t fileSize = (fstat(fd, &st) == 0) ? st.st_size : 0;
        if (fileSize <= 0) {
            return;
        }
        SBScanLoadCommands(header, filePtr, fileSize, ^(uint32_t cmd, void *cmdPtr, BOOL *stop) {
            if (cmd != LC_MAIN) {
                return;
            }
            struct entry_point_command *entryPoint = (struct entry_point_command *)cmdPtr;
            BOOL isARM64e = (header->cpusubtype & ~CPU_SUBTYPE_LIB64) == CPU_SUBTYPE_ARM64E;
            if (isARM64e) {
                arm64eEntry = entryPoint->entryoff;
                hasARM64e = YES;
            } else if (!hasARM64) {
                arm64Entry = entryPoint->entryoff;
                hasARM64 = YES;
            }
            *stop = YES;
        });
    });
    if (error) {
        return 0;
    }
    if (hasARM64e) {
        if (entryoffOut) {
            *entryoffOut = arm64eEntry;
        }
        return 1;
    }
    if (hasARM64) {
        if (entryoffOut) {
            *entryoffOut = arm64Entry;
        }
        return 1;
    }
    return 0;
}

int SBMachOHasIDDylib(const char *path) {
    __block BOOL sawARM64 = NO;
    __block BOOL allHaveID = YES;
    NSString *error = LCParseMachO(path, true, ^(const char *slicePath, struct mach_header_64 *header, int fd, void *filePtr) {
        (void)slicePath;
        if (header->cputype != CPU_TYPE_ARM64) {
            return;
        }
        sawARM64 = YES;
        struct stat st;
        off_t fileSize = (fstat(fd, &st) == 0) ? st.st_size : 0;
        if (fileSize <= 0) {
            allHaveID = NO;
            return;
        }
        __block BOOL hasID = NO;
        SBScanLoadCommands(header, filePtr, fileSize, ^(uint32_t cmd, void *cmdPtr, BOOL *stop) {
            (void)cmdPtr;
            if (cmd == LC_ID_DYLIB) {
                hasID = YES;
                *stop = YES;
            }
        });
        if (!hasID) {
            allHaveID = NO;
        }
    });
    if (error) {
        return 0;
    }
    return (sawARM64 && allHaveID) ? 1 : 0;
}

void SBLCFixupBundleARM64e(const char *bundlePath) {
    LCPatchAppBundleFixupARM64eSlice(
        [NSURL fileURLWithPath:[NSString stringWithUTF8String:bundlePath]]);
}

int SBLCCheckCodeSignature(const char *path) {
    return checkCodeSignature(path) ? 1 : 0;
}

int SBLCCheckCodeSignatureDetail(const char *path, int *outStep, int *outErrno, char *outMessage, size_t outMessageSize) {
    return checkCodeSignatureDetail(path, outStep, outErrno, outMessage, outMessageSize) ? 1 : 0;
}
