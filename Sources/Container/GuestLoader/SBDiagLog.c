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
#include <dispatch/dispatch.h>
#endif
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
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
#define SB_DIAG_STUCK_PREFIX "stuck-"
#define SB_DIAG_STUCK_SUFFIX ".txt"
/// 0.2.42 看门狗节律（调查报告 §5.3）：主线程心跳 250ms、看门狗检查
/// 500ms、心跳停摆 >5s 熔断、全流程 20s。
#define SB_DIAG_WD_HEARTBEAT_MS 250
#define SB_DIAG_WD_CHECK_MS 500
#define SB_DIAG_WD_STALL_LIMIT_MS 5000
#define SB_DIAG_WD_TOTAL_LIMIT_MS 20000
/// 0.2.44 分级熔断：步超时（慢）与真卡死分开。慢触发后、主线程心跳仍死
/// 超过该宽限才升级为真卡死 exit；宽限内主线程返回即干净失败、可重试。
#define SB_DIAG_WD_SLOW_GRACE_MS 5000
/// slow 连续达该次数升级为 stuck（永久拦，直到指纹/版本变或成功激活清）。
#define SB_DIAG_SLOW_MAX_COUNT 3
/// slow 记录过期时限（秒）：超期即失效、可再试。
#define SB_DIAG_SLOW_EXPIRY_SECONDS 86400
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
/// 0.2.42：BeginRun 从卡死熔断目录读出的上次卡死客与步名（进程内静态区，
/// 供本次启动报“上次卡在某步”；熔断文件本身不删，留到下次点该客时消费）。
static char g_staleStuckGuest[256];
static char g_staleStuckStep[128];

/// 0.2.42 看门狗状态（g_wdLock 串行化；与日志 g_lock 是两把锁，
// 任何路径都不以 g_lock 在手时再取 g_wdLock——看门狗线程读状态时
// 从不持 g_lock，超时写行时用 trylock，绝不让看门狗自己卡在锁上）。
static pthread_mutex_t g_wdLock = PTHREAD_MUTEX_INITIALIZER;
static int g_wdArmed = 0;
static unsigned long g_wdGeneration = 0;
static char g_wdBundleID[256];
static char g_wdFingerprint[512];
static char g_wdHostVersion[128];
static char g_wdStep[64];
static uint64_t g_wdStepTimeoutMs = 0;
static uint64_t g_wdStepStartMs = 0;
static uint64_t g_wdFlowStartMs = 0;
static volatile uint64_t g_wdLastHeartbeatMs = 0;
static int g_wdTimedOut = 0;
/// 0.2.44：步超时（慢）标志——看门狗线程置位，不杀进程；主线程在 dlopen
/// 返回后消费（见 SBDiagLogWatchdogConsumeSlowTimeout），置位即干净失败
/// “加载超时，请重试”。g_wdSlowAtMs 是置位时刻（单调时钟），宽限计时用。
static int g_wdSlowTimedOut = 0;
static uint64_t g_wdSlowAtMs = 0;
/// 超时写熔断时用的熔断目录快照（武装时从 g_fuseDir 拷；BeginRun 后即稳定）。
static char g_wdFuseDir[PATH_MAX + 64];
#if defined(__APPLE__)
static dispatch_source_t g_wdHeartbeatTimer = NULL;
#endif

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
    // 0.2.42：卡死熔断还在 = 上次启动死在点开某步里（看门狗写下熔断后
    // exit）。熔断文件不删（须留到下次点该客时由 Is 检查消费或由成功
    // 激活清掉），故每次启动都再报一次——一行诊断，不拦启动。
    // 只读第一份（readdir 顺序），多份时计数写进同一行。
    char staleStuckGuest[256] = {0};
    char staleStuckStep[128] = {0};
    double staleStuckElapsed = 0;
    int staleStuckCount = 0;
    int hasStaleStuck = 0;
    if (g_fuseDir[0] != '\0') {
        DIR *fuseDir = opendir(g_fuseDir);
        if (fuseDir) {
            struct dirent *ent;
            while ((ent = readdir(fuseDir)) != NULL) {
                const char *name = ent->d_name;
                size_t nlen = strlen(name);
                size_t preLen = strlen(SB_DIAG_STUCK_PREFIX);
                size_t sufLen = strlen(SB_DIAG_STUCK_SUFFIX);
                if (strncmp(name, SB_DIAG_STUCK_PREFIX, preLen) != 0) {
                    continue;
                }
                if (nlen < preLen + sufLen ||
                    strcmp(name + nlen - sufLen, SB_DIAG_STUCK_SUFFIX) != 0) {
                    continue;
                }
                staleStuckCount++;
                if (hasStaleStuck) {
                    continue; // 只读第一份
                }
                // bundleID = 文件名去前后缀（写时已做安全字符转换，不再还原）。
                size_t bidLen = nlen - preLen - sufLen;
                if (bidLen >= sizeof(staleStuckGuest)) {
                    bidLen = sizeof(staleStuckGuest) - 1;
                }
                memcpy(staleStuckGuest, name + preLen, bidLen);
                staleStuckGuest[bidLen] = '\0';
                char fusePath[PATH_MAX + 64];
                if (snprintf(fusePath, sizeof(fusePath), "%s/%s", g_fuseDir, name) >= (int)sizeof(fusePath)) {
                    continue;
                }
                size_t contentLen = 0;
                char *content = SBDiagReadFile(fusePath, &contentLen);
                if (content && contentLen > 0) {
                    // 六行：步名、耗时秒、指纹、宿主版本、kind、计数/时间戳——只取前两行。
                    char *nl1 = strchr(content, '\n');
                    if (nl1) {
                        *nl1 = '\0';
                    }
                    (void)snprintf(staleStuckStep, sizeof(staleStuckStep), "%s", content);
                    if (nl1) {
                        char *line2 = nl1 + 1;
                        char *nl2 = strchr(line2, '\n');
                        if (nl2) {
                            *nl2 = '\0';
                        }
                        staleStuckElapsed = atof(line2);
                    }
                    hasStaleStuck = 1;
                    size_t gl = strlen(staleStuckGuest);
                    if (gl < sizeof(g_staleStuckGuest)) {
                        memcpy(g_staleStuckGuest, staleStuckGuest, gl + 1);
                    }
                    size_t sl = strlen(staleStuckStep);
                    if (sl < sizeof(g_staleStuckStep)) {
                        memcpy(g_staleStuckStep, staleStuckStep, sl + 1);
                    }
                }
                free(content);
            }
            closedir(fuseDir);
        }
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
    if (hasStaleStuck) {
        char line[512];
        int n = snprintf(line, sizeof(line),
                         "上次启动卡在 %s 里（客=%s，步耗时约 %.1f 秒，看门狗已熔断该客，下次点开将干净失败%s）",
                         staleStuckStep[0] != '\0' ? staleStuckStep : "未知步骤",
                         staleStuckGuest[0] != '\0' ? staleStuckGuest : "（未知）",
                         staleStuckElapsed,
                         staleStuckCount > 1 ? "，另有卡死熔断在位" : "");
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

#pragma mark - 0.2.42 卡死熔断记录（看门狗超时写下）

/// 0.2.42：卡死熔断记录路径（<熔断目录>/stuck-<bundleID>.txt）。
/// 与 SBDiagWillConnectBlockPath 同款（目录同一把锁下取、bundle ID
/// 只留 [A-Za-z0-9.-]）；目录为空（BeginRun 未跑）时返回 0。
static int SBDiagStuckPath(const char *guestBundleID, char *out, size_t outLen, int *outIsShared) {
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
                      SB_DIAG_STUCK_PREFIX, safe,
                      SB_DIAG_STUCK_SUFFIX);
    return rc > 0 && (size_t)rc < outLen;
}

/// 超时路径用的熔断路径（不拿锁：调用方传武装时快照的熔断目录）。
static int SBDiagStuckPathFromDir(const char *dir, const char *guestBundleID,
                                  char *out, size_t outLen) {
    if (!dir || dir[0] == '\0' || !guestBundleID || guestBundleID[0] == '\0' ||
        !out || outLen == 0) {
        return 0;
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
                      SB_DIAG_STUCK_PREFIX, safe,
                      SB_DIAG_STUCK_SUFFIX);
    return rc > 0 && (size_t)rc < outLen;
}

/// 熔断文件内容（0.2.44 起六行：步名、步耗时秒、客指纹、宿主版本、
/// kind（slow | stuck）、计数/时间戳）。旧四行记录读时按 slow 计一次
///（见 IsGuestStuckForGuest）；升 0.2.44 改了宿主版本，旧记录本就因
/// 版本对不上而失效，无需迁移。
static int SBDiagStuckContent(const char *step, double elapsedSeconds,
                              const char *fingerprint, const char *hostVersion,
                              const char *kind, int count, long long timestamp,
                              char *out, size_t outLen) {
    int n = snprintf(out, outLen, "%s\n%.1f\n%s\n%s\n%s\n%d/%lld\n",
                     (step && step[0] != '\0') ? step : "未知步骤",
                     elapsedSeconds,
                     (fingerprint && fingerprint[0] != '\0') ? fingerprint : "?",
                     (hostVersion && hostVersion[0] != '\0') ? hostVersion : "?",
                     (kind && kind[0] != '\0') ? kind : "stuck",
                     count, timestamp);
    return n > 0 && (size_t)n < outLen;
}

/// 六行熔断记录原样写盘（不拿日志锁、不记日志行——超时路径上调）。
static void SBDiagWriteStuckRecord(const char *path, const char *step,
                                   double elapsedSeconds,
                                   const char *fingerprint,
                                   const char *hostVersion,
                                   const char *kind, int count,
                                   long long timestamp) {
    char content[1024];
    if (!SBDiagStuckContent(step, elapsedSeconds, fingerprint, hostVersion,
                            kind, count, timestamp,
                            content, sizeof(content))) {
        return;
    }
    SBDiagWriteFile(path, content, strlen(content));
}

void SBDiagLogMarkStuckGuest(const char *guestBundleID, const char *step, double elapsedSeconds, const char *fingerprint, const char *hostVersion) {
    char path[PATH_MAX + 64];
    int isShared = 0;
    if (!SBDiagStuckPath(guestBundleID, path, sizeof(path), &isShared)) {
        return;
    }
    SBDiagWriteStuckRecord(path, step, elapsedSeconds, fingerprint, hostVersion,
                           "stuck", 1, (long long)time(NULL));
    {
        char line[512];
        int ln = snprintf(line, sizeof(line), "卡死熔断记录已写%s：%s（%s）",
                          isShared ? "共享区" : "Logs", guestBundleID,
                          (step && step[0] != '\0') ? step : "未知步骤");
        if (ln > 0) {
            SBDiagLogLine(line);
        }
    }
}

int SBDiagLogIsGuestStuckForGuest(const char *guestBundleID, const char *fingerprint, const char *hostVersion, char *stepOut, size_t stepOutSize) {
    if (stepOut && stepOutSize > 0) {
        stepOut[0] = '\0';
    }
    char path[PATH_MAX + 64];
    int isShared = 0;
    if (!SBDiagStuckPath(guestBundleID, path, sizeof(path), &isShared)) {
        return 0;
    }
    size_t len = 0;
    char *content = SBDiagReadFile(path, &len);
    int stuck = 0;
    const char *why = "无记录";
    if (content && len > 0) {
        // 六行：步名、耗时秒、指纹、宿主版本、kind、计数/时间戳——指纹与
        // 版本两行都对上才继续看 kind；任一不符（重装/升级）即失效、自动重试。
        // kind 缺失 = 旧四行记录，按 slow 计一次（可重试，不永久封）。
        char *nl1 = strchr(content, '\n');
        if (!nl1) {
            why = "记录损坏（不是四行）";
        } else {
            *nl1 = '\0';
            char *line2 = nl1 + 1;
            char *nl2 = strchr(line2, '\n');
            if (!nl2) {
                why = "记录损坏（不是四行）";
            } else {
                *nl2 = '\0';
                char *line3 = nl2 + 1;
                char *nl3 = strchr(line3, '\n');
                if (!nl3) {
                    why = "记录损坏（不是四行）";
                } else {
                    *nl3 = '\0';
                    char *line4 = nl3 + 1;
                    char *nl4 = strchr(line4, '\n');
                    if (nl4) {
                        *nl4 = '\0';
                    }
                    if (!(fingerprint && strcmp(line3, fingerprint) == 0 &&
                          hostVersion && strcmp(line4, hostVersion) == 0)) {
                        why = "记录不符（指纹/版本已变）";
                    } else {
                        // 指纹与版本均对上：看 kind（第 5 行）与计数/时间戳（第 6 行）。
                        char *kind = NULL;
                        char *countLine = NULL;
                        if (nl4) {
                            kind = nl4 + 1;
                            char *nl5 = strchr(kind, '\n');
                            if (nl5) {
                                *nl5 = '\0';
                                countLine = nl5 + 1;
                                char *nl6 = strchr(countLine, '\n');
                                if (nl6) {
                                    *nl6 = '\0';
                                }
                            }
                        }
                        if (!kind || kind[0] == '\0') {
                            // 旧四行记录：按 slow 计一次，可重试。
                            why = "旧记录（按 slow 计 1 次，可重试）";
                        } else if (strcmp(kind, "stuck") == 0) {
                            stuck = 1;
                            why = "指纹与宿主版本均对上";
                        } else if (strcmp(kind, "slow") == 0) {
                            int count = 0;
                            long long ts = 0;
                            if (countLine) {
                                (void)sscanf(countLine, "%d/%lld", &count, &ts);
                            }
                            if (count <= 0) {
                                count = 1;
                            }
                            long long now = (long long)time(NULL);
                            if (ts > 0 && now - ts > SB_DIAG_SLOW_EXPIRY_SECONDS) {
                                why = "慢加载记录已过期（>24h），可再试";
                            } else if (count >= SB_DIAG_SLOW_MAX_COUNT) {
                                stuck = 1;
                                why = "慢加载连续 3 次，已升级熔断";
                            } else {
                                static char slowWhy[128];
                                (void)snprintf(slowWhy, sizeof(slowWhy),
                                               "慢加载计数 %d（可重试）", count);
                                why = slowWhy;
                            }
                        } else {
                            why = "记录 kind 未知，不拦";
                        }
                        if (stuck && stepOut && stepOutSize > 0) {
                            (void)snprintf(stepOut, stepOutSize, "%s", content);
                        }
                    }
                }
            }
        }
    }
    free(content);
    {
        char line[512];
        int ln = snprintf(line, sizeof(line), "卡死熔断检查：%s 熔断=%s（%s，%s）",
                          guestBundleID, stuck ? "是" : "否",
                          isShared ? "共享区" : "Logs", why);
        if (ln > 0) {
            SBDiagLogLine(line);
        }
    }
    return stuck;
}

/// 读一份熔断记录里的 slow 计数与时间戳（只认 kind=slow 的六行记录；
/// 旧四行按计数 1 计；无记录/非 slow 返回计数 0）。供看门狗线程写下一
/// 次 slow 记录时计数 +1 用（超时路径，不拿日志锁）。
static int SBDiagSlowCountFromDir(const char *dir, const char *guestBundleID,
                                  int *countOut, long long *tsOut) {
    if (countOut) {
        *countOut = 0;
    }
    if (tsOut) {
        *tsOut = 0;
    }
    char path[PATH_MAX + 64];
    if (!SBDiagStuckPathFromDir(dir, guestBundleID, path, sizeof(path))) {
        return 0;
    }
    size_t len = 0;
    char *content = SBDiagReadFile(path, &len);
    if (!content || len == 0) {
        free(content);
        return 0;
    }
    int count = 0;
    long long ts = 0;
    // 逐行走到第 5 行 kind、第 6 行计数/时间戳；行数不足即旧四行记录。
    char *cur = content;
    int lineNo = 0;
    char *kind = NULL;
    char *countLine = NULL;
    while (cur && *cur != '\0') {
        lineNo++;
        char *nl = strchr(cur, '\n');
        if (nl) {
            *nl = '\0';
        }
        if (lineNo == 5) {
            kind = cur;
        } else if (lineNo == 6) {
            countLine = cur;
        }
        if (!nl) {
            break;
        }
        cur = nl + 1;
    }
    if (!kind || kind[0] == '\0') {
        // 旧四行记录：按 slow 计一次。
        count = 1;
    } else if (strcmp(kind, "slow") == 0 && countLine) {
        (void)sscanf(countLine, "%d/%lld", &count, &ts);
        if (count <= 0) {
            count = 1;
        }
    } else {
        // stuck 记录或 kind 未知：slow 计数从 0 起（不沿用 stuck 的计数）。
        count = 0;
    }
    free(content);
    if (countOut) {
        *countOut = count;
    }
    if (tsOut) {
        *tsOut = ts;
    }
    return 1;
}

void SBDiagLogClearStuckGuestForGuest(const char *guestBundleID) {
    char path[PATH_MAX + 64];
    int isShared = 0;
    if (!SBDiagStuckPath(guestBundleID, path, sizeof(path), &isShared)) {
        return;
    }
    // 只在真删掉记录文件时记一行（文件本就不存在时不记，免得把
    // “无记录”说成“已清”）。
    if (unlink(path) == 0) {
        char line[512];
        int ln = snprintf(line, sizeof(line), "卡死熔断记录已清：%s（%s）",
                          guestBundleID, isShared ? "共享区" : "Logs");
        if (ln > 0) {
            SBDiagLogLine(line);
        }
    }
}

const char *SBDiagLogStaleStuckGuest(void) {
    return g_staleStuckGuest;
}

const char *SBDiagLogStaleStuckStep(void) {
    return g_staleStuckStep;
}

#pragma mark - 0.2.42 点开流程分步看门狗

/// 单调时钟毫秒（CLOCK_MONOTONIC，进程启动起算，不受系统时间改动影响）。
static uint64_t SBDiagMonotonicMs(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return (uint64_t)ts.tv_sec * 1000U + (uint64_t)(ts.tv_nsec / 1000000);
}

/// 心跳打点：主线程每 250ms 调一次。
/// iOS 上由主队列 dispatch timer 调；非 Apple 构建无 dispatch，
/// 测试驱动直接调本函数模拟主线程心跳（见本文件末尾说明）。
/// 注意：非 static——Linux 原型用它驱动同一份看门狗代码；iOS 上
/// 只由主队列 timer 调，绝不在别的线程调（否则心跳失去意义）。
void SBDiagWatchdogHeartbeatTick(void) {
    g_wdLastHeartbeatMs = SBDiagMonotonicMs();
}

#if defined(__APPLE__)
static void SBDiagWatchdogHeartbeatTickF(void *context) {
    (void)context;
    SBDiagWatchdogHeartbeatTick();
}
#endif

/// 超时行的时间戳（与 SBDiagLogLine 同格式 "[MM-DD HH:MM:SS.mmm]"，
/// 超时路径不走 SBDiagLogLine，故这里单抄一份，不依赖正常写盘路）。
static void SBDiagTimeoutTimestamp(char *out, size_t outSize) {
    struct timeval tv;
    struct tm tmv;
    if (gettimeofday(&tv, NULL) == 0 && localtime_r(&tv.tv_sec, &tmv) != NULL) {
        char datePart[24];
        if (strftime(datePart, sizeof(datePart), "%m-%d %H:%M:%S", &tmv) == 0) {
            datePart[0] = '\0';
        }
        (void)snprintf(out, outSize, "%s.%03d", datePart, (int)(tv.tv_usec / 1000));
    } else {
        (void)snprintf(out, outSize, "??.?? ??:??:??.???");
    }
}

/// 写一行 WATCHDOG TIMEOUT（超时路径专用：先 trylock 走正常写盘路，
/// 拿不到锁直接对 g_fd 写＋fsync，死点信息一定落盘；不拿日志锁等待）。
static void SBDiagWriteTimeoutLine(const char *step, const char *why,
                                   uint64_t stepMs, uint64_t flowMs) {
    char ts[32];
    SBDiagTimeoutTimestamp(ts, sizeof(ts));
    char line[1024];
    int n = snprintf(line, sizeof(line),
                     "[%s] WATCHDOG TIMEOUT at %s（%s，步耗时 %llums，全流程 %llums）\n",
                     ts, (step && step[0] != '\0') ? step : "未知步骤", why,
                     (unsigned long long)stepMs, (unsigned long long)flowMs);
    if (n <= 0) {
        return;
    }
    if (pthread_mutex_trylock(&g_lock) == 0) {
        if (g_begun && g_fd >= 0) {
            SBDiagWriteAll(g_fd, line, (size_t)n);
        }
        pthread_mutex_unlock(&g_lock);
    } else {
        int fd = g_fd; // BeginRun 后即稳定；未 BeginRun 时为 -1，不写
        if (fd >= 0) {
            SBDiagWriteAll(fd, line, (size_t)n);
        }
    }
}

/// 0.2.44：slow 记录写盘（看门狗线程调）：计数 = 旧记录计数 +1（旧四行
/// 按 1 计），kind=slow，时间戳=现在。不杀进程、不 exit。
static void SBDiagMarkSlowGuest(const char *guestBundleID, const char *step,
                                double elapsedSeconds, const char *fingerprint,
                                const char *hostVersion, const char *fuseDir) {
    if (!fuseDir || fuseDir[0] == '\0' || !guestBundleID || guestBundleID[0] == '\0') {
        return;
    }
    char path[PATH_MAX + 64];
    if (!SBDiagStuckPathFromDir(fuseDir, guestBundleID, path, sizeof(path))) {
        return;
    }
    int prevCount = 0;
    long long prevTs = 0;
    (void)SBDiagSlowCountFromDir(fuseDir, guestBundleID, &prevCount, &prevTs);
    long long now = (long long)time(NULL);
    // 24h 过期的 slow 记录重新从 1 计（过期即失效，不累计旧债）。
    int count = (prevTs > 0 && now - prevTs > SB_DIAG_SLOW_EXPIRY_SECONDS) ? 1 : prevCount + 1;
    SBDiagWriteStuckRecord(path, step, elapsedSeconds, fingerprint, hostVersion,
                           "slow", count, now);
}

/// 超时落点（只在看门狗线程跑）：写 WATCHDOG TIMEOUT 行＋熔断标记，
// 然后主动 exit(0) 把手机还给用户。正常情况下不返回。
// 写行先 trylock 拿 g_lock 走正常写盘路；拿不到（主线程正卡在写日志
// 里）也不等——直接对 g_fd 写＋fsync，行内容可能与别的行交错，
// 但死点信息一定落盘。熔断标记用裸 open/write/fsync，不拿任何锁、
// 不调 ObjC、不碰 UIKit——超时路径上绝不引入新的阻塞点。
static void SBDiagWatchdogTimeout(const char *step, const char *why,
                                  uint64_t stepMs, uint64_t flowMs,
                                  const char *bundleID,
                                  const char *fingerprint,
                                  const char *hostVersion,
                                  const char *fuseDir) {
    SBDiagWriteTimeoutLine(step, why, stepMs, flowMs);
    // 熔断标记（超时路径不经过 SBDiagLogMarkStuckGuest——后者会记日志行
    // 取 g_lock；这里只写文件）。kind=stuck，六行格式。
    if (fuseDir && fuseDir[0] != '\0' && bundleID && bundleID[0] != '\0') {
        char path[PATH_MAX + 64];
        if (SBDiagStuckPathFromDir(fuseDir, bundleID, path, sizeof(path))) {
            SBDiagWriteStuckRecord(path, step, (double)stepMs / 1000.0,
                                   fingerprint, hostVersion,
                                   "stuck", 1, (long long)time(NULL));
        }
    }
    // 看门狗解不开已死锁的主线程：冻住的进程留着只会让用户以为手机坏了；
    // 退出后宿主下次启动读到熔断标记，弹“该应用上次打开时卡住了，已跳过”
    // 并停在桌面。绝不静默重试、绝不无限等待。
    exit(0);
}

/// 看门狗线程：每 500ms 检查一次。武装解除或 generation 变化即退出。
/// 只做读时间戳＋（超时时）写文件＋exit，不调 ObjC、不碰 UIKit。
static void *SBDiagWatchdogThread(void *arg) {
    (void)arg;
    unsigned long generation = 0;
    pthread_mutex_lock(&g_wdLock);
    generation = g_wdGeneration;
    pthread_mutex_unlock(&g_wdLock);
    for (;;) {
        struct timespec ts = { 0, SB_DIAG_WD_CHECK_MS * 1000 * 1000 };
        (void)nanosleep(&ts, NULL);
        char step[64] = {0};
        char bundleID[256] = {0};
        char fingerprint[512] = {0};
        char hostVersion[128] = {0};
        char fuseDir[PATH_MAX + 64] = {0};
        uint64_t stepStart = 0, stepTimeout = 0, flowStart = 0, lastBeat = 0;
        pthread_mutex_lock(&g_wdLock);
        if (!g_wdArmed || g_wdGeneration != generation) {
            pthread_mutex_unlock(&g_wdLock);
            return NULL;
        }
        (void)snprintf(step, sizeof(step), "%s", g_wdStep);
        (void)snprintf(bundleID, sizeof(bundleID), "%s", g_wdBundleID);
        (void)snprintf(fingerprint, sizeof(fingerprint), "%s", g_wdFingerprint);
        (void)snprintf(hostVersion, sizeof(hostVersion), "%s", g_wdHostVersion);
        (void)snprintf(fuseDir, sizeof(fuseDir), "%s", g_wdFuseDir);
        stepStart = g_wdStepStartMs;
        stepTimeout = g_wdStepTimeoutMs;
        flowStart = g_wdFlowStartMs;
        lastBeat = g_wdLastHeartbeatMs;
        pthread_mutex_unlock(&g_wdLock);
        uint64_t now = SBDiagMonotonicMs();
        const char *why = NULL;
        uint64_t stepMs = (now >= stepStart) ? (now - stepStart) : 0;
        uint64_t flowMs = (now >= flowStart) ? (now - flowStart) : 0;
        uint64_t stallMs = (now >= lastBeat) ? (now - lastBeat) : 0;
        // 0.2.44：判定顺序改——有步阈值在跑时步超时优先，停摆只在无步
        // （step == "armed" 或步间缝隙）时触发。0.2.42 的顺序让 dlopen
        // 这种主线程同步步永远等不到自己的 10s 步阈值：心跳是主队列
        // timer，主线程一进 dlopen 就停打点，5s 停摆恒先于 10s 步超时成立
        //（抖音 5040ms 的 dlopen 就是这么被当成卡死的）。
        int stepActive = (stepTimeout > 0 && step[0] != '\0');
        if (stepActive) {
            if (stepMs > stepTimeout) {
                // 步超时 = 慢，不是卡死：只置 slow 标志、写 slow 记录，
                // 不 exit。主线程在 dlopen 返回后消费标志位、干净失败
                // “加载超时，请重试”，可立即再点。慢触发后心跳仍死满
                // 宽限（5s）才升级为真卡死 exit。
                int slowFire = 0;
                uint64_t slowAt = 0;
                pthread_mutex_lock(&g_wdLock);
                if (!g_wdSlowTimedOut) {
                    g_wdSlowTimedOut = 1;
                    g_wdSlowAtMs = now;
                    slowFire = 1;
                }
                slowAt = g_wdSlowAtMs;
                pthread_mutex_unlock(&g_wdLock);
                if (slowFire) {
                    SBDiagWriteTimeoutLine(step, "步超时（慢加载，可重试）", stepMs, flowMs);
                    SBDiagMarkSlowGuest(bundleID, step, (double)stepMs / 1000.0,
                                        fingerprint, hostVersion, fuseDir);
                }
                if (stallMs > SB_DIAG_WD_STALL_LIMIT_MS &&
                    now >= slowAt && now - slowAt > SB_DIAG_WD_SLOW_GRACE_MS) {
                    why = "步超时后心跳仍停摆";
                } else if (flowMs > SB_DIAG_WD_TOTAL_LIMIT_MS) {
                    why = "全流程超时";
                }
            } else if (flowMs > SB_DIAG_WD_TOTAL_LIMIT_MS) {
                why = "全流程超时";
            }
        } else if (stallMs > SB_DIAG_WD_STALL_LIMIT_MS) {
            why = "主线程心跳停摆";
        } else if (flowMs > SB_DIAG_WD_TOTAL_LIMIT_MS) {
            why = "全流程超时";
        }
        if (!why) {
            continue;
        }
        // 只触发一次：超时后进程立即 exit，合作式取消实际上走不到
        // （StepBegin 里的 timedOut 检查只是防御，见 build log）。
        pthread_mutex_lock(&g_wdLock);
        if (g_wdTimedOut) {
            pthread_mutex_unlock(&g_wdLock);
            return NULL;
        }
        g_wdTimedOut = 1;
        pthread_mutex_unlock(&g_wdLock);
        SBDiagWatchdogTimeout(step, why, stepMs, flowMs, bundleID,
                              fingerprint, hostVersion, fuseDir);
        return NULL; // Timeout 正常情况下不返回（exit）；防御性退出
    }
}

void SBDiagLogWatchdogArm(const char *guestBundleID) {
    if (!guestBundleID || guestBundleID[0] == '\0') {
        return;
    }
    // 熔断目录快照（BeginRun 后即稳定；武装在 BeginRun 前时为空，
    // 超时行照写、熔断标记跳过——诊断不丢，熔断缺一次）。
    char fuseDir[PATH_MAX + 64] = {0};
    pthread_mutex_lock(&g_lock);
    if (g_fuseDir[0] != '\0') {
        size_t dl = strlen(g_fuseDir);
        if (dl < sizeof(fuseDir)) {
            memcpy(fuseDir, g_fuseDir, dl + 1);
        }
    }
    pthread_mutex_unlock(&g_lock);
    uint64_t now = SBDiagMonotonicMs();
    pthread_mutex_lock(&g_wdLock);
    if (g_wdArmed) {
        // 已武装（另一客流程未结束）时先解除旧的：generation++ 让旧线程
        // 退出，旧心跳 timer 一并取消；新流程接管。
        g_wdGeneration++;
#if defined(__APPLE__)
        if (g_wdHeartbeatTimer) {
            dispatch_source_cancel(g_wdHeartbeatTimer);
            g_wdHeartbeatTimer = NULL;
        }
#endif
    }
    g_wdArmed = 1;
    g_wdGeneration++;
    g_wdTimedOut = 0;
    g_wdSlowTimedOut = 0;
    g_wdSlowAtMs = 0;
    (void)snprintf(g_wdBundleID, sizeof(g_wdBundleID), "%s", guestBundleID);
    g_wdFingerprint[0] = '\0';
    g_wdHostVersion[0] = '\0';
    (void)snprintf(g_wdStep, sizeof(g_wdStep), "%s", "armed");
    g_wdStepTimeoutMs = 0;
    g_wdStepStartMs = now;
    g_wdFlowStartMs = now;
    g_wdLastHeartbeatMs = now;
    (void)snprintf(g_wdFuseDir, sizeof(g_wdFuseDir), "%s", fuseDir);
    pthread_mutex_unlock(&g_wdLock);
#if defined(__APPLE__)
    // 主队列心跳 timer：每 250ms 打点（只写一个 volatile 时间戳，
    // 不记日志、不碰锁、不调 ObjC）。主线程卡住时 timer 不跑，
    // 心跳停摆即被看门狗线程看到。
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                     0, 0, dispatch_get_main_queue());
    if (timer) {
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  SB_DIAG_WD_HEARTBEAT_MS * NSEC_PER_MSEC,
                                  50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler_f(timer, SBDiagWatchdogHeartbeatTickF);
        dispatch_resume(timer);
        pthread_mutex_lock(&g_wdLock);
        if (g_wdArmed) {
            g_wdHeartbeatTimer = timer;
        } else {
            dispatch_source_cancel(timer);
        }
        pthread_mutex_unlock(&g_wdLock);
    }
#endif
    // 看门狗线程（detached；解除武装或 generation 变化即退出）。
    pthread_t th;
    if (pthread_create(&th, NULL, SBDiagWatchdogThread, NULL) == 0) {
        (void)pthread_detach(th);
    }
    {
        char line[512];
        int n = snprintf(line, sizeof(line),
                         "看门狗已武装：%s（心跳 250ms／检查 500ms／停摆 >5s 熔断 exit／全流程 20s）",
                         guestBundleID);
        if (n > 0) {
            SBDiagLogLine(line);
        }
    }
}

void SBDiagLogWatchdogDisarmForGuest(const char *guestBundleID) {
    if (!guestBundleID || guestBundleID[0] == '\0') {
        return;
    }
    int wasArmed = 0;
    uint64_t flowMs = 0;
    pthread_mutex_lock(&g_wdLock);
    if (g_wdArmed && strcmp(g_wdBundleID, guestBundleID) == 0) {
        wasArmed = 1;
        uint64_t now = SBDiagMonotonicMs();
        flowMs = (now >= g_wdFlowStartMs) ? (now - g_wdFlowStartMs) : 0;
        g_wdArmed = 0;
        g_wdSlowTimedOut = 0;
        g_wdSlowAtMs = 0;
        g_wdGeneration++;
#if defined(__APPLE__)
        if (g_wdHeartbeatTimer) {
            dispatch_source_cancel(g_wdHeartbeatTimer);
            g_wdHeartbeatTimer = NULL;
        }
#endif
    }
    pthread_mutex_unlock(&g_wdLock);
    if (wasArmed) {
        char line[512];
        int n = snprintf(line, sizeof(line), "看门狗解除：%s（全流程耗时 %llums）",
                         guestBundleID, (unsigned long long)flowMs);
        if (n > 0) {
            SBDiagLogLine(line);
        }
    }
}

void SBDiagLogWatchdogSetGuestFingerprint(const char *fingerprint, const char *hostVersion) {
    pthread_mutex_lock(&g_wdLock);
    if (g_wdArmed) {
        (void)snprintf(g_wdFingerprint, sizeof(g_wdFingerprint), "%s",
                       (fingerprint && fingerprint[0] != '\0') ? fingerprint : "?");
        (void)snprintf(g_wdHostVersion, sizeof(g_wdHostVersion), "%s",
                       (hostVersion && hostVersion[0] != '\0') ? hostVersion : "?");
    }
    pthread_mutex_unlock(&g_wdLock);
}

void SBDiagLogWatchdogStepBegin(const char *step, double timeoutSeconds) {
    if (!step || step[0] == '\0') {
        return;
    }
    uint64_t now = SBDiagMonotonicMs();
    int armed = 0;
    uint64_t flowMs = 0;
    pthread_mutex_lock(&g_wdLock);
    if (g_wdArmed && !g_wdTimedOut) {
        armed = 1;
        g_wdSlowTimedOut = 0;
        g_wdSlowAtMs = 0;
        // 0.2.44：步开始即主线程存活证明——刷新心跳。否则慢 dlopen
        // 返回后、解除武装前，看门狗下一轮会在“无步”分支里看到 dlopen
        // 期间冻住的心跳时间戳，误判停摆而 exit（slow 设计就白做了）。
        g_wdLastHeartbeatMs = now;
        (void)snprintf(g_wdStep, sizeof(g_wdStep), "%s", step);
        g_wdStepStartMs = now;
        g_wdStepTimeoutMs = (timeoutSeconds > 0)
            ? (uint64_t)(timeoutSeconds * 1000.0) : 0;
        flowMs = (now >= g_wdFlowStartMs) ? (now - g_wdFlowStartMs) : 0;
    }
    pthread_mutex_unlock(&g_wdLock);
    if (armed) {
        char line[512];
        int n = snprintf(line, sizeof(line),
                         "看门狗：进入 %s（阈值 %.0fs，全流程已用 %llums）",
                         step, timeoutSeconds, (unsigned long long)flowMs);
        if (n > 0) {
            SBDiagLogLine(line);
        }
    }
}

void SBDiagLogWatchdogStepEnd(const char *step) {
    if (!step || step[0] == '\0') {
        return;
    }
    uint64_t now = SBDiagMonotonicMs();
    int armed = 0;
    uint64_t stepMs = 0;
    pthread_mutex_lock(&g_wdLock);
    if (g_wdArmed && strcmp(g_wdStep, step) == 0) {
        armed = 1;
        stepMs = (now >= g_wdStepStartMs) ? (now - g_wdStepStartMs) : 0;
        g_wdStep[0] = '\0';
        g_wdStepTimeoutMs = 0;
        // 0.2.44：同 StepBegin——步结束即存活证明，刷新心跳，免得
        // “无步”分支用旧时间戳误判停摆。
        g_wdLastHeartbeatMs = now;
    }
    pthread_mutex_unlock(&g_wdLock);
    if (armed) {
        char line[512];
        int n = snprintf(line, sizeof(line), "看门狗：退出 %s（耗时 %llums）",
                         step, (unsigned long long)stepMs);
        if (n > 0) {
            SBDiagLogLine(line);
        }
    }
}

/// 主线程消费 slow 标志位：返回 1 表示本流程里某步曾超时（慢），调用
/// 后清零（只消费一次）。dlopen 返回后调：置位即干净失败“加载超时，
/// 请重试”，不跳 main、不 exit。
int SBDiagLogWatchdogConsumeSlowTimeout(void) {
    int slow = 0;
    pthread_mutex_lock(&g_wdLock);
    slow = g_wdSlowTimedOut;
    g_wdSlowTimedOut = 0;
    g_wdSlowAtMs = 0;
    pthread_mutex_unlock(&g_wdLock);
    return slow;
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
