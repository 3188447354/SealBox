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
