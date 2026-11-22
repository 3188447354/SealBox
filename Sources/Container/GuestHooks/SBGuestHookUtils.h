// SBGuestHookUtils.h — 客端 Hook 共用的小辅助：找客可执行镜像头、读钥匙串组名。
// 只用公开头文件；本文件只被 GuestHooks target 里的 .m 包含。
#ifndef SBGuestHookUtils_h
#define SBGuestHookUtils_h

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

/// 0.2.44（B-4，GuestHooks target 内联版——与 GuestLoader 的
/// SBGuestImageHeaderForDiskFile 同款判定顺序，宿主侧不包含本头，
/// 两处须同步改）：LC_UUID 优先 → 全路径 → basename 仅当全进程恰好
/// 一个同名镜像；同名多镜像时拒绝（返回 NULL），绝不静默绑错镜像。
static inline int SBGuestHookDiskUUID(const char *path, uint8_t uuidOut[16]) {
    if (!path || !uuidOut) {
        return 0;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return 0;
    }
    uint32_t magic = 0;
    if (pread(fd, &magic, sizeof(magic), 0) != (ssize_t)sizeof(magic)) {
        close(fd);
        return 0;
    }
    off_t sliceOff = 0;
    if (magic == FAT_CIGAM) {
        struct fat_header fh;
        if (pread(fd, &fh, sizeof(fh), 0) != (ssize_t)sizeof(fh)) {
            close(fd);
            return 0;
        }
        uint32_t n = OSSwapBigToHostInt32(fh.nfat_arch);
        if (n > 64) {
            close(fd);
            return 0;
        }
        int found = 0;
        for (uint32_t i = 0; i < n; i++) {
            struct fat_arch fa;
            if (pread(fd, &fa, sizeof(fa), (off_t)sizeof(fh) + (off_t)i * (off_t)sizeof(fa)) != (ssize_t)sizeof(fa)) {
                break;
            }
            if (OSSwapBigToHostInt32(fa.cputype) == CPU_TYPE_ARM64) {
                sliceOff = OSSwapBigToHostInt32(fa.offset);
                found = 1;
                break;
            }
        }
        if (!found) {
            close(fd);
            return 0;
        }
    } else if (magic != MH_MAGIC_64) {
        close(fd);
        return 0;
    }
    struct mach_header_64 mh;
    if (pread(fd, &mh, sizeof(mh), sliceOff) != (ssize_t)sizeof(mh)) {
        close(fd);
        return 0;
    }
    if (mh.magic != MH_MAGIC_64 || mh.sizeofcmds > 1024 * 1024) {
        close(fd);
        return 0;
    }
    uint8_t *cmds = malloc(mh.sizeofcmds);
    if (!cmds) {
        close(fd);
        return 0;
    }
    ssize_t got = pread(fd, cmds, mh.sizeofcmds, sliceOff + (off_t)sizeof(mh));
    close(fd);
    if (got != (ssize_t)mh.sizeofcmds) {
        free(cmds);
        return 0;
    }
    uint32_t off = 0;
    for (uint32_t i = 0; i < mh.ncmds; i++) {
        if (off + sizeof(struct load_command) > mh.sizeofcmds) {
            break;
        }
        struct load_command *lc = (struct load_command *)(cmds + off);
        if (lc->cmdsize < sizeof(struct load_command) || off + lc->cmdsize > mh.sizeofcmds) {
            break;
        }
        if (lc->cmd == LC_UUID) {
            struct uuid_command *uc = (struct uuid_command *)lc;
            memcpy(uuidOut, uc->uuid, 16);
            free(cmds);
            return 1;
        }
        off += lc->cmdsize;
    }
    free(cmds);
    return 0;
}

static inline int SBGuestHookMemoryUUID(const struct mach_header *header, uint8_t uuidOut[16]) {
    if (!header || !uuidOut || header->magic != MH_MAGIC_64) {
        return 0;
    }
    const struct mach_header_64 *h64 = (const struct mach_header_64 *)header;
    if (h64->ncmds > 1024) {
        return 0;
    }
    struct load_command *lc = (struct load_command *)(h64 + 1);
    for (uint32_t i = 0; i < h64->ncmds; i++) {
        if (lc->cmd == LC_UUID) {
            memcpy(uuidOut, ((struct uuid_command *)lc)->uuid, 16);
            return 1;
        }
        if (lc->cmdsize < sizeof(struct load_command)) {
            return 0;
        }
        lc = (struct load_command *)((uint8_t *)lc + lc->cmdsize);
    }
    return 0;
}

static inline const char *SBGuestHookBasename(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

/// 客可执行文件在当前进程里的 mach_header：按环境变量 SB_GUEST_EXEC_PATH
///（宿主 SBGuestBootstrap 在 dlopen 前写好）找；找不到时返回 NULL。
static inline const struct mach_header *SBGuestImageHeader(void) {
    const char *execPath = getenv("SB_GUEST_EXEC_PATH");
    if (!execPath) {
        return NULL;
    }
    uint32_t count = _dyld_image_count();
    uint8_t diskUUID[16];
    if (SBGuestHookDiskUUID(execPath, diskUUID)) {
        for (uint32_t i = 0; i < count; i++) {
            const struct mach_header *h = _dyld_get_image_header(i);
            uint8_t memUUID[16];
            if (h && SBGuestHookMemoryUUID(h, memUUID) && memcmp(memUUID, diskUUID, 16) == 0) {
                return h;
            }
        }
    }
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strcmp(name, execPath) == 0) {
            return _dyld_get_image_header(i);
        }
    }
    const char *base = SBGuestHookBasename(execPath);
    const struct mach_header *found = NULL;
    uint32_t matches = 0;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strcmp(SBGuestHookBasename(name), base) == 0) {
            matches++;
            found = _dyld_get_image_header(i);
        }
    }
    return (matches == 1) ? found : NULL;
}

/// 该客容器用的钥匙串组名：环境变量 SB_GUEST_KEYCHAIN_GROUP（宿主写好），
/// 格式 com.mjorb.sealbox.shared[.N]；没有则退回组 0。
static inline NSString *SBGuestKeychainGroupName(void) {
    const char *group = getenv("SB_GUEST_KEYCHAIN_GROUP");
    if (group && group[0] != '\0') {
        return [NSString stringWithUTF8String:group];
    }
    return @"com.mjorb.sealbox.shared";
}

#endif /* SBGuestHookUtils_h */
