// SBDiagLog.c — 启动诊断日志：纯 C 实现，不依赖 Foundation。
//
// 0.2.4 新增：0.2.3 的闪退修完真机还在崩，根因靠猜查不出来。
// 从此每次启动的每一步都实时写盘刷盘，崩了最后一步还在；
// 下次启动认得出上次崩了，把那份日志留下来，设置页能看到、能分享。
//
// 0.2.31（MJ 01:04 立规：诊断日志做进文件夹、不许断）：每次启动一份日志
// 文件，放 Documents/Logs 文件夹（SBStartupLog-<启动时间>-<pid>.txt）；
// 保留上限 20 个文件 / 总计 2MB，最旧先删、永不删当前文件；旧 DiagLogs
// 目录的日志一次性迁移过来（无完成标记的加 -crashed）；设置页查看页改成
// 文件列表（崩溃徽章＋大小）→ 点进看全文。
//
// 写穿：每行 write + fsync（SBDiagWriteAll）。write 是同步系统调用——
// 数据进内核页缓存后进程再怎么死（abort、SIGKILL、EXC_BREAKPOINT、
// 断言崩）都丢不掉；fsync 再把页缓存刷到闪存，连掉电都不丢。
// 崩溃杀的是进程不是内核，所以“写完即落盘”：原型 diaglog0231-verify.c
// 在 Linux 上实测写行后直接 abort，读回文件行数齐全（见 build log）。
//
// 安全：本文件所有函数永不崩、不抛错、不弹框——任何失败都静默丢弃。
// 路径在 BeginRun 时一次算好并缓存（之后客 App 启动会改 HOME 环境变量，
// 缓存的路径不受影响）。写操作一把互斥锁串行化，每行 write + fsync。
#include "SBDiagLog.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#if defined(__APPLE__)
#include <objc/message.h>
#include <objc/runtime.h>
#endif
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define SB_DIAG_MARKER "=== STARTUP COMPLETE ==="
#define SB_DIAG_MAX_BYTES (1024 * 1024)
#define SB_DIAG_READ_CAP (SB_DIAG_MAX_BYTES + 1024)
#define SB_DIAG_FILE_PREFIX "SBStartupLog"
#define SB_DIAG_DLOPEN_MARKER_NAME "SBStartupLog-dlopen-marker.txt"
#define SB_DIAG_WILLCONNECT_MARKER_NAME "SBStartupLog-willconnect-marker.txt"
#define SB_DIAG_WILLCONNECT_BLOCK_PREFIX "willconnect-blocked-"
#define SB_DIAG_WILLCONNECT_BLOCK_SUFFIX ".txt"
#define SB_DIAG_MAX_FILES 20
#define SB_DIAG_MAX_TOTAL_BYTES (2 * 1024 * 1024)

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_begun = 0;
static int g_fd = -1;
static long g_bytesWritten = 0;
static int g_capLogged = 0;
static char g_dir[PATH_MAX + 64];
/// 0.2.38：熔断记录生效目录——App Group 共享区里的 SBDiag 子目录（重装宿主
/// 换容器也不丢）；共享区不可用时回落到 Logs（g_dir，与 0.2.37 一致）。
static char g_fuseDir[PATH_MAX + 64];
static int g_fuseDirIsShared = 0;
static char g_currentPath[PATH_MAX + 64];
static char g_currentName[256];
static char g_dlopenMarkerPath[PATH_MAX + 64];
static char g_willConnectMarkerPath[PATH_MAX + 64];
/// 0.2.37：BeginRun 从残留 willConnect 标记读出的客 bundle ID（进程内静态区，
/// 供本次启动的 driveSceneManually 熔断用；无残留标记时为空串）。
static char g_staleWillConnectGuest[256];

/// 读整个文件（上限 SB_DIAG_READ_CAP），NUL 结尾；失败返回 NULL。
static char *SBDiagReadFile(const char *path, size_t *lenOut) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return NULL;
    }
    size_t cap = 64 * 1024;
    size_t len = 0;
    char *buf = (char *)malloc(cap + 1);
    if (!buf) {
        close(fd);
        return NULL;
    }
    for (;;) {
        if (len == cap) {
            if (cap >= SB_DIAG_READ_CAP) {
                break;
            }
            size_t newCap = cap * 2;
            if (newCap > SB_DIAG_READ_CAP) {
                newCap = SB_DIAG_READ_CAP;
            }
            char *grown = (char *)realloc(buf, newCap + 1);
            if (!grown) {
                free(buf);
                close(fd);
                return NULL;
            }
            buf = grown;
            cap = newCap;
        }
        ssize_t n = read(fd, buf + len, cap - len);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (n == 0) {
            break;
        }
        len += (size_t)n;
    }
    close(fd);
    buf[len] = '\0';
    if (lenOut) {
        *lenOut = len;
    }
    return buf;
}

/// 写整个文件（覆盖），写完 fsync；失败静默返回。
static void SBDiagWriteFile(const char *path, const char *data, size_t len) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        return;
    }
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, data + off, len - off);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (n == 0) {
            break;
        }
        off += (size_t)n;
    }
    (void)fsync(fd);
    (void)close(fd);
}

/// 把 buf 全写进 fd，写完 fsync；失败静默返回。
static void SBDiagWriteAll(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return;
        }
        if (n == 0) {
            return;
        }
        off += (size_t)n;
    }
    (void)fsync(fd);
}

/// 文件任意位置是否含完成标记。
// 0.2.36：之前只读尾部 4KB，但标记写在启动初期（第 9 行附近）；日志超过 4KB
//（几行签名逐项就上万字节）时标记早已滑出尾部窗口，任何正常启动的长日志
// 下次都会被误改名 -crashed——0.2.35 的 7 份日志全都 >10KB，标记全不在
// 尾部 4KB 里，6 份被误标 -crashed（第 7 份只是还没等到下次启动来改名）。
// -crashed 后缀本身不能证明进程崩了（183539 的进程结束原因仍查不到，
// 见 build log 0.2.36 节）。改读全文搜标记（单文件上限 1MB）。
static int SBDiagFileHasMarker(const char *path) {
    size_t len = 0;
    char *text = SBDiagReadFile(path, &len);
    if (!text) {
        return 0;
    }
    int found = strstr(text, SB_DIAG_MARKER) != NULL;
    free(text);
    return found;
}

/// 是否日志文件名（SBStartupLog- 开头、.txt 结尾，dlopen 标记文件除外）。
static int SBDiagIsLogFileName(const char *name) {
    if (strncmp(name, SB_DIAG_FILE_PREFIX "-", 13) != 0) { // "SBStartupLog-"
        return 0;
    }
    size_t len = strlen(name);
    if (len < 5 || strcmp(name + len - 4, ".txt") != 0) {
        return 0;
    }
    if (strcmp(name, SB_DIAG_DLOPEN_MARKER_NAME) == 0) {
        return 0;
    }
    if (strcmp(name, SB_DIAG_WILLCONNECT_MARKER_NAME) == 0) {
        return 0;
    }
    return 1;
}

typedef struct {
    char name[256];
    int crashed; // 名字含 "-crashed"
    long bytes;
} SBDiagFileEntry;

static int SBDiagFileEntryCompare(const void *a, const void *b) {
    return strcmp(((const SBDiagFileEntry *)a)->name,
                  ((const SBDiagFileEntry *)b)->name);
}

/// 列出日志文件夹里全部日志文件（不含 dlopen 标记文件），按文件名升序
/// （= 时间升序，因文件名含 YYYY-MM-DD-HHMMSS）。返回 malloc 的数组，
/// countOut 写个数；失败返回 NULL。假定调用方已持锁。
static SBDiagFileEntry *SBDiagListFiles(size_t *countOut) {
    if (countOut) {
        *countOut = 0;
    }
    if (g_dir[0] == '\0') {
        return NULL;
    }
    DIR *dir = opendir(g_dir);
    if (!dir) {
        return NULL;
    }
    size_t cap = 16, count = 0;
    SBDiagFileEntry *files = (SBDiagFileEntry *)malloc(cap * sizeof(*files));
    if (!files) {
        closedir(dir);
        return NULL;
    }
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL) {
        const char *name = ent->d_name;
        if (!SBDiagIsLogFileName(name)) {
            continue;
        }
        char path[PATH_MAX + 64];
        if (snprintf(path, sizeof(path), "%s/%s", g_dir, name) >= (int)sizeof(path)) {
            continue;
        }
        struct stat st;
        if (stat(path, &st) != 0) {
            continue;
        }
        if (count == cap) {
            size_t newCap = cap * 2;
            SBDiagFileEntry *grown = (SBDiagFileEntry *)realloc(files, newCap * sizeof(*files));
            if (!grown) {
                break;
            }
            files = grown;
            cap = newCap;
        }
        (void)snprintf(files[count].name, sizeof(files[count].name), "%s", name);
        files[count].crashed = strstr(name, "-crashed") != NULL;
        files[count].bytes = (long)st.st_size;
        count++;
    }
    closedir(dir);
    if (count > 1) {
        qsort(files, count, sizeof(*files), SBDiagFileEntryCompare);
    }
    if (countOut) {
        *countOut = count;
    }
    return files;
}

/// 生成本次启动的文件名：SBStartupLog-<YYYY-MM-DD-HHMMSS>-<pid>.txt。
static void SBDiagMakeRunName(char *out, size_t outSize, time_t t, pid_t pid) {
    struct tm tmv;
    char datePart[24] = "0000-00-00-000000";
    if (localtime_r(&t, &tmv) != NULL) {
        (void)strftime(datePart, sizeof(datePart), "%Y-%m-%d-%H%M%S", &tmv);
    }
    (void)snprintf(out, outSize, "%s-%s-%d.txt", SB_DIAG_FILE_PREFIX, datePart, (int)pid);
}

/// 0.2.31 一次性迁移：把旧 DiagLogs 目录（0.2.4–0.2.30）的日志搬到新
// Logs 目录。旧 current/previous/crashed 按 mtime 改名；旧 current 内容里
// 无完成标记的加 -crashed（它就是上次崩的日志）；dlopen 标记文件原名搬过来。
// 任何失败都静默跳过（目标已存在时不覆盖）。搬完旧目录只剩空壳时 rmdir
// 删掉（删不掉也不管）。假定调用方已持锁。
static void SBDiagMigrateOldLogs(const char *home) {
    char oldDir[PATH_MAX + 64];
    int rc = snprintf(oldDir, sizeof(oldDir), "%s/Documents/DiagLogs", home);
    if (rc < 0 || (size_t)rc >= sizeof(oldDir)) {
        return;
    }
    if (access(oldDir, F_OK) != 0) {
        return; // 没有旧目录，无事可做
    }
    static const char *oldNames[3] = {
        "SBStartupLog-current.txt",
        "SBStartupLog-previous.txt",
        "SBStartupLog-crashed.txt",
    };
    static const char *roleSuffix[3] = {
        "-migrated", "-migrated-previous", "-migrated-crashed",
    };
    for (int i = 0; i < 3; i++) {
        char oldPath[PATH_MAX + 64];
        if (snprintf(oldPath, sizeof(oldPath), "%s/%s", oldDir, oldNames[i]) >= (int)sizeof(oldPath)) {
            continue;
        }
        struct stat st;
        if (stat(oldPath, &st) != 0) {
            continue;
        }
        char datePart[24] = "0000-00-00-000000";
        struct tm tmv;
        if (localtime_r(&st.st_mtime, &tmv) != NULL) {
            (void)strftime(datePart, sizeof(datePart), "%Y-%m-%d-%H%M%S", &tmv);
        }
        char newName[256];
        if (i == 0 && !SBDiagFileHasMarker(oldPath)) {
            // 旧 current 无完成标记：它就是上次崩的日志，加 -crashed。
            if (snprintf(newName, sizeof(newName), "%s-%s-migrated-crashed.txt",
                         SB_DIAG_FILE_PREFIX, datePart) >= (int)sizeof(newName)) {
                continue;
            }
        } else {
            if (snprintf(newName, sizeof(newName), "%s-%s%s.txt",
                         SB_DIAG_FILE_PREFIX, datePart, roleSuffix[i]) >= (int)sizeof(newName)) {
                continue;
            }
        }
        char newPath[PATH_MAX + 64];
        if (snprintf(newPath, sizeof(newPath), "%s/%s", g_dir, newName) >= (int)sizeof(newPath)) {
            continue;
        }
        if (access(newPath, F_OK) == 0) {
            continue; // 已搬过，不覆盖
        }
        (void)rename(oldPath, newPath);
    }
    // dlopen 标记文件原名搬过来（下次启动仍能认出上次死在 dlopen 里）。
    {
        char oldMarker[PATH_MAX + 64], newMarker[PATH_MAX + 64];
        if (snprintf(oldMarker, sizeof(oldMarker), "%s/%s", oldDir, SB_DIAG_DLOPEN_MARKER_NAME) < (int)sizeof(oldMarker) &&
            snprintf(newMarker, sizeof(newMarker), "%s/%s", g_dir, SB_DIAG_DLOPEN_MARKER_NAME) < (int)sizeof(newMarker) &&
            access(newMarker, F_OK) != 0) {
            (void)rename(oldMarker, newMarker);
        }
    }
    (void)rmdir(oldDir);
}

/// 最新一份日志若无完成标记，改名加 -crashed（上次启动中途崩了）。
// 假定调用方已持锁。
static void SBDiagRenameLatestIfCrashed(void) {
    size_t count = 0;
    SBDiagFileEntry *files = SBDiagListFiles(&count);
    if (!files || count == 0) {
        free(files);
        return;
    }
    SBDiagFileEntry latest = files[count - 1]; // 按名升序，最后一个即最新
    if (latest.crashed) {
        free(files);
        return;
    }
    char path[PATH_MAX + 64];
    if (snprintf(path, sizeof(path), "%s/%s", g_dir, latest.name) >= (int)sizeof(path)) {
        free(files);
        return;
    }
    if (SBDiagFileHasMarker(path)) {
        free(files);
        return;
    }
    size_t nameLen = strlen(latest.name);
    if (nameLen < 5 || strcmp(latest.name + nameLen - 4, ".txt") != 0) {
        free(files);
        return;
    }
    char newName[256];
    if (snprintf(newName, sizeof(newName), "%.*s-crashed.txt", (int)(nameLen - 4), latest.name) >= (int)sizeof(newName)) {
        free(files);
        return;
    }
    char newPath[PATH_MAX + 64];
    if (snprintf(newPath, sizeof(newPath), "%s/%s", g_dir, newName) < (int)sizeof(newPath)) {
        (void)rename(path, newPath);
    }
    free(files);
}

/// 保留上限：最多 20 个文件、总计 2MB；最旧先删，永不删当前文件。
// 假定调用方已持锁。
static void SBDiagPrune(void) {
    size_t count = 0;
    SBDiagFileEntry *files = SBDiagListFiles(&count);
    if (!files) {
        return;
    }
    long total = 0;
    for (size_t i = 0; i < count; i++) {
        total += files[i].bytes;
    }
    for (size_t i = 0; i < count && (count > SB_DIAG_MAX_FILES || total > SB_DIAG_MAX_TOTAL_BYTES); i++) {
        if (g_currentName[0] != '\0' && strcmp(files[i].name, g_currentName) == 0) {
            continue; // 永不删当前文件
        }
        char path[PATH_MAX + 64];
        if (snprintf(path, sizeof(path), "%s/%s", g_dir, files[i].name) >= (int)sizeof(path)) {
            continue;
        }
        if (unlink(path) == 0) {
            total -= files[i].bytes;
            count--;
        }
    }
    free(files);
}

#if defined(__APPLE__)
/// 0.2.38：App Group 共享区里的熔断记录目录（<组容器>/SBDiag），成功时写进
/// out 并返回 1。解析办法与注入件签名检查同一路
/// （FileManager.containerURL(forSecurityApplicationGroupIdentifier:
/// SBConstants.appGroupSuiteName)，套件名＝"group."＋Bundle.main.bundleIdentifier，
/// 真机上即 group.com.mjorb.sealbox.3432ZHJUF9，日志里报“共享区=可用
/// 组容器=可用”的那路）——纯 C 文件不能直接调 Foundation，经 ObjC 运行时调
/// （id／SEL 显式转型，arm64 必备；与 SBGuestSessionManager.m 里
/// objc_msgSend 绕 NS_UNAVAILABLE 的写法同款）。只在调用当场用返回的
/// NSURL／NSString 取路径并立即拷进 C 缓冲，不持有 ObjC 对象。失败返回 0
/// （调用方回落到 Logs，不丢熔断）。非 Apple 平台无 ObjC 运行时，直接返回 0。
static int SBDiagSharedDir(char *out, size_t outSize) {
    if (!out || outSize == 0) {
        return 0;
    }
    Class nsBundleClass = objc_getClass("NSBundle");
    Class nsFileManagerClass = objc_getClass("NSFileManager");
    Class nsStringClass = objc_getClass("NSString");
    if (!nsBundleClass || !nsFileManagerClass || !nsStringClass) {
        return 0;
    }
    id mainBundle = ((id (*)(id, SEL))objc_msgSend)((id)nsBundleClass,
                                                    sel_registerName("mainBundle"));
    if (!mainBundle) {
        return 0;
    }
    id bundleID = ((id (*)(id, SEL))objc_msgSend)(mainBundle,
                                                  sel_registerName("bundleIdentifier"));
    char bundleIDBuf[256];
    bundleIDBuf[0] = '\0';
    if (bundleID) {
        const char *s = ((const char *(*)(id, SEL))objc_msgSend)(bundleID,
                                                                 sel_registerName("UTF8String"));
        if (s && s[0] != '\0') {
            (void)snprintf(bundleIDBuf, sizeof(bundleIDBuf), "%s", s);
        }
    }
    if (bundleIDBuf[0] == '\0') {
        (void)snprintf(bundleIDBuf, sizeof(bundleIDBuf), "com.mjorb.sealbox");
    }
    char suite[512];
    if (snprintf(suite, sizeof(suite), "group.%s", bundleIDBuf) >= (int)sizeof(suite)) {
        return 0;
    }
    id suiteStr = ((id (*)(id, SEL, const char *))objc_msgSend)(
        (id)nsStringClass, sel_registerName("stringWithUTF8String:"), suite);
    if (!suiteStr) {
        return 0;
    }
    id fm = ((id (*)(id, SEL))objc_msgSend)((id)nsFileManagerClass,
                                           sel_registerName("defaultManager"));
    if (!fm) {
        return 0;
    }
    id url = ((id (*)(id, SEL, id))objc_msgSend)(
        fm, sel_registerName("containerURLForSecurityApplicationGroupIdentifier:"),
        suiteStr);
    if (!url) {
        return 0;
    }
    const char *fsRep = ((const char *(*)(id, SEL))objc_msgSend)(
        url, sel_registerName("fileSystemRepresentation"));
    if (!fsRep || fsRep[0] == '\0') {
        return 0;
    }
    char shared[PATH_MAX + 64];
    if (snprintf(shared, sizeof(shared), "%s/SBDiag", fsRep) >= (int)sizeof(shared)) {
        return 0;
    }
    (void)mkdir(shared, 0755);
    if (access(shared, W_OK) != 0) {
        return 0;
    }
    if (snprintf(out, outSize, "%s", shared) >= (int)outSize) {
        return 0;
    }
    return 1;
}
#else
static int SBDiagSharedDir(char *out, size_t outSize) {
    (void)out;
    (void)outSize;
    return 0;
}
#endif

/// 0.2.38：搬一个熔断记录文件（Logs → 共享区）。目标不存在直接 rename；
/// 目标已存在时按 mtime 定：源更新就覆盖，否则删源的旧份（共享区为准）。
/// 返回 1＝真搬过去了（rename 成功），0＝删旧份或无事可做（调用方计数用）。
static int SBDiagMigrateOneFuseFile(const char *src, const char *dst) {
    struct stat srcSt, dstSt;
    if (stat(src, &srcSt) != 0) {
        return 0;
    }
    if (stat(dst, &dstSt) == 0) {
        if (srcSt.st_mtime > dstSt.st_mtime) {
            return rename(src, dst) == 0;
        }
        (void)unlink(src);
        return 0;
    }
    return rename(src, dst) == 0;
}

/// 0.2.38：把 Logs 里残留的熔断记录搬到共享区（0.2.37 升 0.2.38 不重装时，
/// 彩云的拦截记录还在旧 Logs 里；不搬就丢了，下次点彩云会再死一次才重建）。
/// 搬 willconnect-blocked-*.txt（拦截记录）与 willConnect 进入标记（单文件）。
/// 只在共享区可用时搬；返回搬走的文件数（0＝无事可做）。假定调用方已持锁。
static int SBDiagMigrateFuseFiles(void) {
    if (!g_fuseDirIsShared || g_dir[0] == '\0' || g_fuseDir[0] == '\0') {
        return 0;
    }
    if (strcmp(g_fuseDir, g_dir) == 0) {
        return 0;
    }
    int moved = 0;
    DIR *dir = opendir(g_dir);
    if (dir) {
        size_t prefixLen = strlen(SB_DIAG_WILLCONNECT_BLOCK_PREFIX);
        size_t suffixLen = strlen(SB_DIAG_WILLCONNECT_BLOCK_SUFFIX);
        struct dirent *ent;
        while ((ent = readdir(dir)) != NULL) {
            const char *name = ent->d_name;
            size_t nlen = strlen(name);
            if (strncmp(name, SB_DIAG_WILLCONNECT_BLOCK_PREFIX, prefixLen) != 0) {
                continue;
            }
            if (nlen < suffixLen ||
                strcmp(name + nlen - suffixLen, SB_DIAG_WILLCONNECT_BLOCK_SUFFIX) != 0) {
                continue;
            }
            char src[PATH_MAX + 64], dst[PATH_MAX + 64];
            if (snprintf(src, sizeof(src), "%s/%s", g_dir, name) >= (int)sizeof(src)) {
                continue;
            }
            if (snprintf(dst, sizeof(dst), "%s/%s", g_fuseDir, name) >= (int)sizeof(dst)) {
                continue;
            }
            moved += SBDiagMigrateOneFuseFile(src, dst);
        }
        closedir(dir);
    }
    {
        char src[PATH_MAX + 64], dst[PATH_MAX + 64];
        if (snprintf(src, sizeof(src), "%s/%s", g_dir, SB_DIAG_WILLCONNECT_MARKER_NAME) < (int)sizeof(src) &&
            snprintf(dst, sizeof(dst), "%s/%s", g_fuseDir, SB_DIAG_WILLCONNECT_MARKER_NAME) < (int)sizeof(dst)) {
            moved += SBDiagMigrateOneFuseFile(src, dst);
        }
    }
    return moved;
}

void SBDiagLogBeginRun(void) {
    int migratedFuseFiles = 0;
    pthread_mutex_lock(&g_lock);
    if (g_begun) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    g_begun = 1;
    const char *home = getenv("HOME");
    if (!home || home[0] == '\0') {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    int rc = snprintf(g_dir, sizeof(g_dir), "%s/Documents/Logs", home);
    if (rc < 0 || (size_t)rc >= sizeof(g_dir)) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    rc = snprintf(g_dlopenMarkerPath, sizeof(g_dlopenMarkerPath), "%s/%s", g_dir, SB_DIAG_DLOPEN_MARKER_NAME);
    if (rc < 0 || (size_t)rc >= sizeof(g_dlopenMarkerPath)) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    // 0.2.38：熔断记录生效目录——先试 App Group 共享区（重装宿主换容器也不丢），
    // 不可用时回落到 Logs（与 0.2.37 一致，重装会丢）。dlopen 标记仍在 Logs
    // （只作诊断，不拦启动；丢了不致再死一回，不搬）。
    g_fuseDir[0] = '\0';
    g_fuseDirIsShared = 0;
    {
        char shared[PATH_MAX + 64];
        if (SBDiagSharedDir(shared, sizeof(shared))) {
            size_t sl = strlen(shared);
            if (sl < sizeof(g_fuseDir)) {
                memcpy(g_fuseDir, shared, sl + 1);
                g_fuseDirIsShared = 1;
            }
        }
        if (!g_fuseDirIsShared) {
            size_t dl = strlen(g_dir);
            if (dl < sizeof(g_fuseDir)) {
                memcpy(g_fuseDir, g_dir, dl + 1);
            }
        }
    }
    // 0.2.36：willConnect 标记路径与 dlopen 标记同款；0.2.38：改到熔断目录——
    // 进入标记与拦截记录同病（重装丢标记→下次启动写不出拦截记录→再死一次），
    // 一并挪到共享区。
    rc = snprintf(g_willConnectMarkerPath, sizeof(g_willConnectMarkerPath), "%s/%s", g_fuseDir, SB_DIAG_WILLCONNECT_MARKER_NAME);
    if (rc < 0 || (size_t)rc >= sizeof(g_willConnectMarkerPath)) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    // 上一级 Documents 不一定存在（如测试沙盒）：先建它再建 Logs。
    // 设备上容器目录本就存在，两次 mkdir 都是空操作。
    {
        char docsDir[PATH_MAX + 64];
        int docsRc = snprintf(docsDir, sizeof(docsDir), "%s/Documents", home);
        if (docsRc > 0 && (size_t)docsRc < sizeof(docsDir)) {
            (void)mkdir(docsDir, 0755);
            (void)mkdir(g_dir, 0755);
        }
    }
    // 0.2.31：旧 DiagLogs 目录一次性迁移到 Logs；上次最新一份若无完成标记
    // 改名加 -crashed；再开本次启动的新文件。
    SBDiagMigrateOldLogs(home);
    SBDiagRenameLatestIfCrashed();
    // 0.2.38：Logs 里残留的熔断记录搬到共享区（须在读残留 willConnect 标记之前，
    // 否则搬过来的标记读不到，本次启动写不出拦截记录）。
    migratedFuseFiles = SBDiagMigrateFuseFiles();
    struct timeval nowTv;
    time_t now = time(NULL);
    if (gettimeofday(&nowTv, NULL) == 0) {
        now = nowTv.tv_sec;
    }
    SBDiagMakeRunName(g_currentName, sizeof(g_currentName), now, getpid());
    rc = snprintf(g_currentPath, sizeof(g_currentPath), "%s/%s", g_dir, g_currentName);
    if (rc < 0 || (size_t)rc >= sizeof(g_currentPath)) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    g_fd = open(g_currentPath, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
    g_bytesWritten = 0;
    g_capLogged = 0;
    // 保留上限（20 个文件 / 总计 2MB），最旧先删，永不删当前文件。
    SBDiagPrune();
    // 0.2.24：dlopen 标记还在 = 上次启动死在 dlopen 里（0.2.23 闪退就是
    // 死在这里，日志断在“进程身份已改写为客应用”）。先读出客 bundle ID、
    // 删掉标记（只报一次），再开新日志文件，行写在“进程启动”之后。
    char staleDlopenGuest[256] = {0};
    int hasStaleDlopenMarker = 0;
    if (g_dlopenMarkerPath[0] != '\0') {
        size_t markerLen = 0;
        char *marker = SBDiagReadFile(g_dlopenMarkerPath, &markerLen);
        if (marker && markerLen > 0) {
            hasStaleDlopenMarker = 1;
            size_t copyLen = markerLen < sizeof(staleDlopenGuest) - 1
                ? markerLen : sizeof(staleDlopenGuest) - 1;
            memcpy(staleDlopenGuest, marker, copyLen);
            staleDlopenGuest[copyLen] = '\0';
            // 去掉行尾换行，只留 bundle ID。
            char *nl = strchr(staleDlopenGuest, '\n');
            if (nl) {
                *nl = '\0';
            }
        }
        free(marker);
        (void)unlink(g_dlopenMarkerPath);
    }
    // 0.2.36：willConnect 标记还在 = 上次启动死在客 scene delegate willConnect
    // 里（Swift trap 抓不住，日志只断在“调用…”行；有此标记不用靠缺行推断）。
    char staleWillConnectGuest[256] = {0};
    int hasStaleWillConnectMarker = 0;
    if (g_willConnectMarkerPath[0] != '\0') {
        size_t markerLen = 0;
        char *marker = SBDiagReadFile(g_willConnectMarkerPath, &markerLen);
        if (marker && markerLen > 0) {
            hasStaleWillConnectMarker = 1;
            size_t copyLen = markerLen < sizeof(staleWillConnectGuest) - 1
                ? markerLen : sizeof(staleWillConnectGuest) - 1;
            memcpy(staleWillConnectGuest, marker, copyLen);
            staleWillConnectGuest[copyLen] = '\0';
            char *nl = strchr(staleWillConnectGuest, '\n');
            if (nl) {
                *nl = '\0';
            }
            // 0.2.37：记进程内静态区——本次启动的 driveSceneManually 靠它熔断
            //（标记文件本身在这里删掉，只报一次；静态区留到进程结束）。
            size_t staticLen = strlen(staleWillConnectGuest);
            if (staticLen >= sizeof(g_staleWillConnectGuest)) {
                staticLen = sizeof(g_staleWillConnectGuest) - 1;
            }
            memcpy(g_staleWillConnectGuest, staleWillConnectGuest, staticLen);
            g_staleWillConnectGuest[staticLen] = '\0';
        }
        free(marker);
        (void)unlink(g_willConnectMarkerPath);
    }
    pthread_mutex_unlock(&g_lock);
    SBDiagLogLine("进程启动");
    {
        // 第 2 行记当前文件名：贴出来的日志能对上文件夹里的哪一份。
        char fileLine[512];
        int n = snprintf(fileLine, sizeof(fileLine), "日志文件：%s", g_currentName);
        if (n > 0) {
            SBDiagLogLine(fileLine);
        }
    }
    // 0.2.38：熔断记录目录写进日志（共享区＝重装不丢；Logs＝共享区不可用、
    // 重装会丢）＋本次迁移数（只在搬过文件时记一行）。
    if (g_fuseDirIsShared) {
        char fuseLine[PATH_MAX + 128];
        int n = snprintf(fuseLine, sizeof(fuseLine),
                         "熔断记录目录：共享区 %s（重装不丢）", g_fuseDir);
        if (n > 0) {
            SBDiagLogLine(fuseLine);
        }
    } else {
        SBDiagLogLine("熔断记录目录：Logs（共享区不可用，重装会丢）");
    }
    if (migratedFuseFiles > 0) {
        char migLine[128];
        int n = snprintf(migLine, sizeof(migLine),
                         "熔断记录已迁到共享区：%d 个", migratedFuseFiles);
        if (n > 0) {
            SBDiagLogLine(migLine);
        }
    }
    if (hasStaleDlopenMarker) {
        char line[512];
        int n = snprintf(line, sizeof(line),
                         "上次启动死在 dlopen 里（标记文件仍在，客=%s）",
                         staleDlopenGuest[0] != '\0' ? staleDlopenGuest : "（未知）");
        if (n > 0) {
            SBDiagLogLine(line);
        }
    }
    if (hasStaleWillConnectMarker) {
        char line[512];
        int n = snprintf(line, sizeof(line),
                         "上次启动死在客 scene delegate willConnect 里（标记文件仍在，客=%s）",
                         staleWillConnectGuest[0] != '\0' ? staleWillConnectGuest : "（未知）");
        if (n > 0) {
            SBDiagLogLine(line);
        }
    }
}

void SBDiagLogLine(const char *step) {
    if (!step || step[0] == '\0') {
        return;
    }
    struct timeval tv;
    struct tm tmv;
    char ts[32];
    if (gettimeofday(&tv, NULL) == 0 && localtime_r(&tv.tv_sec, &tmv) != NULL) {
        char datePart[24];
        if (strftime(datePart, sizeof(datePart), "%m-%d %H:%M:%S", &tmv) == 0) {
            datePart[0] = '\0';
        }
        (void)snprintf(ts, sizeof(ts), "%s.%03d", datePart, (int)(tv.tv_usec / 1000));
    } else {
        (void)snprintf(ts, sizeof(ts), "??.?? ??:??:??.???");
    }
    char line[2048];
    int n = snprintf(line, sizeof(line), "[%s] %s\n", ts, step);
    if (n < 0) {
        return;
    }
    size_t len = (size_t)n;
    if (len >= sizeof(line)) {
        // 超长行截断到缓冲内（留 NUL 与换行位置）。
        len = sizeof(line) - 1;
        line[len - 1] = '\n';
        line[len] = '\0';
    }
    pthread_mutex_lock(&g_lock);
    if (!g_begun || g_fd < 0) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    if (g_bytesWritten >= SB_DIAG_MAX_BYTES) {
        // 单文件到上限：只写一次标记行，之后静默丢行（只丢日志，不拦启动）。
        if (!g_capLogged) {
            g_capLogged = 1;
            char capLine[128];
            int cn = snprintf(capLine, sizeof(capLine),
                              "[%s] 日志已达上限（1MB），后续日志不再记录\n", ts);
            if (cn > 0) {
                SBDiagWriteAll(g_fd, capLine, (size_t)cn);
                g_bytesWritten += (long)cn;
            }
        }
        pthread_mutex_unlock(&g_lock);
        return;
    }
    SBDiagWriteAll(g_fd, line, len);
    g_bytesWritten += (long)len;
    pthread_mutex_unlock(&g_lock);
}

void SBDiagLogMarkStartupComplete(void) {
    SBDiagLogLine(SB_DIAG_MARKER);
}

void SBDiagLogMarkDlopenEntry(const char *guestBundleID) {
    pthread_mutex_lock(&g_lock);
    if (!g_begun || g_dlopenMarkerPath[0] == '\0') {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    char path[PATH_MAX + 64];
    size_t pathLen = strlen(g_dlopenMarkerPath);
    if (pathLen >= sizeof(path)) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    memcpy(path, g_dlopenMarkerPath, pathLen + 1);
    pthread_mutex_unlock(&g_lock);
    // 锁外写文件：写标记本身绝不能阻塞日志锁；内容只有客 bundle ID 一行。
    char content[512];
    int n = snprintf(content, sizeof(content), "%s\n",
                     (guestBundleID && guestBundleID[0] != '\0') ? guestBundleID : "（未知）");
    if (n <= 0) {
        return;
    }
    SBDiagWriteFile(path, content, (size_t)n);
}

void SBDiagLogClearDlopenEntry(void) {
    pthread_mutex_lock(&g_lock);
    if (!g_begun || g_dlopenMarkerPath[0] == '\0') {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    char path[PATH_MAX + 64];
    size_t pathLen = strlen(g_dlopenMarkerPath);
    if (pathLen >= sizeof(path)) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    memcpy(path, g_dlopenMarkerPath, pathLen + 1);
    pthread_mutex_unlock(&g_lock);
    (void)unlink(path);
}

// 0.2.36：willConnect 标记（与 dlopen 标记同款实现，只换路径）。
// 0.2.38：路径已改到熔断目录（共享区，见 BeginRun）；写标记记一行日志。
void SBDiagLogMarkWillConnectEntry(const char *guestBundleID) {
    pthread_mutex_lock(&g_lock);
    if (!g_begun || g_willConnectMarkerPath[0] == '\0') {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    char path[PATH_MAX + 64];
    size_t pathLen = strlen(g_willConnectMarkerPath);
    if (pathLen >= sizeof(path)) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    memcpy(path, g_willConnectMarkerPath, pathLen + 1);
    int isShared = g_fuseDirIsShared;
    pthread_mutex_unlock(&g_lock);
    char content[512];
    int n = snprintf(content, sizeof(content), "%s\n",
                     (guestBundleID && guestBundleID[0] != '\0') ? guestBundleID : "（未知）");
    if (n <= 0) {
        return;
    }
    SBDiagWriteFile(path, content, (size_t)n);
    {
        char line[512];
        int ln = snprintf(line, sizeof(line), "willConnect 进入标记已写%s：%s",
                          isShared ? "共享区" : "Logs",
                          (guestBundleID && guestBundleID[0] != '\0') ? guestBundleID : "（未知）");
        if (ln > 0) {
            SBDiagLogLine(line);
        }
    }
}

void SBDiagLogClearWillConnectEntry(void) {
    pthread_mutex_lock(&g_lock);
    if (!g_begun || g_willConnectMarkerPath[0] == '\0') {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    char path[PATH_MAX + 64];
    size_t pathLen = strlen(g_willConnectMarkerPath);
    if (pathLen >= sizeof(path)) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    memcpy(path, g_willConnectMarkerPath, pathLen + 1);
    int isShared = g_fuseDirIsShared;
    pthread_mutex_unlock(&g_lock);
    // 0.2.38：只在真删掉标记文件时记一行（willConnect 正常返回／抛异常都调
    // 这里；文件本就不存在时不记，免得把“无标记”说成“已清”）。
    if (unlink(path) == 0) {
        char line[512];
        int ln = snprintf(line, sizeof(line), "willConnect 进入标记已清（%s）",
                          isShared ? "共享区" : "Logs");
        if (ln > 0) {
            SBDiagLogLine(line);
        }
    }
}

const char *SBDiagLogStaleWillConnectGuest(void) {
    return g_staleWillConnectGuest;
}

/// 0.2.37：willConnect 拦截记录路径（<熔断目录>/willconnect-blocked-<bundleID>.txt）。
/// 0.2.38：熔断目录改存 App Group 共享区（g_fuseDir）；共享区不可用时回落到
/// Logs（g_dir）。outIsShared 非空时写进目录是不是共享区（调用方记日志用，
/// 与路径同一把锁下取，原子）。bundle ID 只留 [A-Za-z0-9.-]，其余字符变 '_'
/// ——文件名永不含 '/'，不被路径穿越。
static int SBDiagWillConnectBlockPath(const char *guestBundleID, char *out, size_t outLen, int *outIsShared) {
    if (!guestBundleID || guestBundleID[0] == '\0' || !out || outLen == 0) {
        return 0;
    }
    pthread_mutex_lock(&g_lock);
    if (!g_begun) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    const char *fuseDir = g_fuseDir[0] != '\0' ? g_fuseDir : g_dir;
    if (fuseDir[0] == '\0') {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    char dir[PATH_MAX + 64];
    size_t dirLen = strlen(fuseDir);
    if (dirLen >= sizeof(dir)) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    memcpy(dir, fuseDir, dirLen + 1);
    int isShared = g_fuseDirIsShared;
    pthread_mutex_unlock(&g_lock);
    if (outIsShared) {
        *outIsShared = isShared;
    }
    char safe[256];
    size_t i = 0;
    for (; guestBundleID[i] != '\0' && i < sizeof(safe) - 1; i++) {
        char c = guestBundleID[i];
        safe[i] = ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                   (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_')
                      ? c : '_';
    }
    safe[i] = '\0';
    if (i == 0) {
        return 0;
    }
    int rc = snprintf(out, outLen, "%s/%s%s%s", dir,
                      SB_DIAG_WILLCONNECT_BLOCK_PREFIX, safe,
                      SB_DIAG_WILLCONNECT_BLOCK_SUFFIX);
    return rc > 0 && (size_t)rc < outLen;
}

void SBDiagLogBlockWillConnectForGuest(const char *guestBundleID, const char *fingerprint, const char *hostVersion) {
    char path[PATH_MAX + 64];
    int isShared = 0;
    if (!SBDiagWillConnectBlockPath(guestBundleID, path, sizeof(path), &isShared)) {
        return;
    }
    char content[1024];
    int n = snprintf(content, sizeof(content), "%s\n%s\n",
                     (fingerprint && fingerprint[0] != '\0') ? fingerprint : "?",
                     (hostVersion && hostVersion[0] != '\0') ? hostVersion : "?");
    if (n <= 0) {
        return;
    }
    SBDiagWriteFile(path, content, (size_t)n);
    // 0.2.38：写共享区记一行（写到哪、客是谁）。
    {
        char line[512];
        int ln = snprintf(line, sizeof(line), "熔断记录已写%s：%s",
                          isShared ? "共享区" : "Logs", guestBundleID);
        if (ln > 0) {
            SBDiagLogLine(line);
        }
    }
}

int SBDiagLogIsWillConnectBlockedForGuest(const char *guestBundleID, const char *fingerprint, const char *hostVersion) {
    char path[PATH_MAX + 64];
    int isShared = 0;
    if (!SBDiagWillConnectBlockPath(guestBundleID, path, sizeof(path), &isShared)) {
        return 0;
    }
    size_t len = 0;
    char *content = SBDiagReadFile(path, &len);
    int blocked = 0;
    const char *why = "无记录";
    if (content && len > 0) {
        // 两行：指纹、宿主版本——都对上才拦截；任一不符（重装/升级）即失效、自动重试。
        char *nl1 = strchr(content, '\n');
        if (!nl1) {
            why = "记录损坏（不是两行）";
        } else {
            *nl1 = '\0';
            char *line2 = nl1 + 1;
            char *nl2 = strchr(line2, '\n');
            if (nl2) {
                *nl2 = '\0';
            }
            blocked = (fingerprint && strcmp(content, fingerprint) == 0 &&
                       hostVersion && strcmp(line2, hostVersion) == 0);
            why = blocked ? "指纹与宿主版本均对上" : "记录不符（指纹/版本已变）";
        }
    }
    free(content);
    // 0.2.38：读共享区记一行（查到没有、拦截与否、为什么）。
    {
        char line[512];
        int ln = snprintf(line, sizeof(line), "熔断记录检查：%s 拦截=%s（%s，%s）",
                          guestBundleID, blocked ? "是" : "否",
                          isShared ? "共享区" : "Logs", why);
        if (ln > 0) {
            SBDiagLogLine(line);
        }
    }
    return blocked;
}

void SBDiagLogClearWillConnectBlockForGuest(const char *guestBundleID) {
    char path[PATH_MAX + 64];
    int isShared = 0;
    if (!SBDiagWillConnectBlockPath(guestBundleID, path, sizeof(path), &isShared)) {
        return;
    }
    // 0.2.38：只在真删掉记录文件时记一行（重装／willConnect 成功返回都调这里；
    // 文件本就不存在时不记，免得把“无记录”说成“已清”）。
    if (unlink(path) == 0) {
        char line[512];
        int ln = snprintf(line, sizeof(line), "熔断记录已清：%s（%s）",
                          guestBundleID, isShared ? "共享区" : "Logs");
        if (ln > 0) {
            SBDiagLogLine(line);
        }
    }
}

char *SBDiagLogLatestText(void) {
    pthread_mutex_lock(&g_lock);
    char *text = NULL;
    if (g_dir[0] != '\0') {
        size_t count = 0;
        SBDiagFileEntry *files = SBDiagListFiles(&count);
        if (files && count > 0) {
            // 最新崩溃的那份优先，其次最新一份。
            const char *pick = NULL;
            for (size_t i = count; i-- > 0;) {
                if (files[i].crashed) {
                    pick = files[i].name;
                    break;
                }
            }
            if (!pick) {
                pick = files[count - 1].name;
            }
            char path[PATH_MAX + 64];
            if (snprintf(path, sizeof(path), "%s/%s", g_dir, pick) < (int)sizeof(path)) {
                text = SBDiagReadFile(path, NULL);
            }
        }
        free(files);
    }
    pthread_mutex_unlock(&g_lock);
    return text;
}

int SBDiagLogHasCrashedLog(void) {
    pthread_mutex_lock(&g_lock);
    int has = 0;
    if (g_dir[0] != '\0') {
        size_t count = 0;
        SBDiagFileEntry *files = SBDiagListFiles(&count);
        if (files) {
            for (size_t i = 0; i < count; i++) {
                if (files[i].crashed) {
                    has = 1;
                    break;
                }
            }
            free(files);
        }
    }
    pthread_mutex_unlock(&g_lock);
    return has;
}

char *SBDiagLogFileList(void) {
    pthread_mutex_lock(&g_lock);
    char *out = NULL;
    if (g_dir[0] != '\0') {
        size_t count = 0;
        SBDiagFileEntry *files = SBDiagListFiles(&count);
        if (files) {
            size_t cap = 1024, len = 0;
            out = (char *)malloc(cap + 1);
            if (out) {
                out[0] = '\0';
                for (size_t i = count; i-- > 0;) { // 最新在前
                    char line[512];
                    int n = snprintf(line, sizeof(line), "%s\t%d\t%ld\n",
                                     files[i].name, files[i].crashed, files[i].bytes);
                    if (n <= 0) {
                        continue;
                    }
                    if (len + (size_t)n > cap) {
                        size_t newCap = cap * 2;
                        while (newCap < len + (size_t)n) {
                            newCap *= 2;
                        }
                        char *grown = (char *)realloc(out, newCap + 1);
                        if (!grown) {
                            break;
                        }
                        out = grown;
                        cap = newCap;
                    }
                    memcpy(out + len, line, (size_t)n);
                    len += (size_t)n;
                    out[len] = '\0';
                }
            }
            free(files);
        }
    }
    pthread_mutex_unlock(&g_lock);
    return out;
}

char *SBDiagLogReadNamedFile(const char *name) {
    if (!name || name[0] == '\0') {
        return NULL;
    }
    // 只认日志文件夹里的日志文件：拒绝路径穿越（"/"、"\\"、"."、".."），
    // 且必须以 SBStartupLog- 开头、以 .txt 结尾。
    if (strchr(name, '/') || strchr(name, '\\') ||
        strcmp(name, ".") == 0 || strcmp(name, "..") == 0 ||
        !SBDiagIsLogFileName(name)) {
        return NULL;
    }
    pthread_mutex_lock(&g_lock);
    char *text = NULL;
    if (g_dir[0] != '\0') {
        char path[PATH_MAX + 64];
        if (snprintf(path, sizeof(path), "%s/%s", g_dir, name) < (int)sizeof(path)) {
            text = SBDiagReadFile(path, NULL);
        }
    }
    pthread_mutex_unlock(&g_lock);
    return text;
}

char *SBDiagLogCurrentFileName(void) {
    pthread_mutex_lock(&g_lock);
    char *name = NULL;
    if (g_currentName[0] != '\0') {
        name = strdup(g_currentName);
    }
    pthread_mutex_unlock(&g_lock);
    return name;
}
