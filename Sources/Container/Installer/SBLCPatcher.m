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
                } else if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB ||
                           lc->cmd == LC_REEXPORT_DYLIB) {
                    struct dylib_command *dylib = (struct dylib_command *)lc;
                    for (NSDictionary *fw in frameworks) {
                        NSString *fwName = fw[@"name"];
                        NSString *execName = fw[@"execName"];
                        NSString *sharedA = [NSString stringWithFormat:@"@rpath/%@.framework/%@", fwName, execName];
                        NSString *sharedB = [NSString stringWithFormat:@"%@.framework/%@", fwName, execName];
                        NSString *sharedC = execName;
                        if (SBNameEquals(dylib, [sharedA UTF8String]) ||
                            SBNameEquals(dylib, [sharedB UTF8String]) ||
                            SBNameEquals(dylib, [sharedC UTF8String])) {
                            if (!SBNameEquals(dylib, [fw[@"uniqueID"] UTF8String])) {
                                if (SBRewriteDylibName(header, dylib, [fw[@"uniqueID"] UTF8String], &freeBytes)) {
                                    changed = YES;
                                } else {
                                    // 改不了就原样留着（见头注）：未改的 @rpath 引用
                                    // 永远匹配不到别客的唯一名，只会从磁盘正确加载。
                                    warnings++;
                                    fprintf(stderr, "[SB] namespace: cannot rewrite reference %s in %s (no room)\n",
                                            [fw[@"uniqueID"] UTF8String], filePathC);
                                }
                            }
                            break;
                        }
                    }
                }
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
