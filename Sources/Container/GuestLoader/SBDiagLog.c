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
#define SB_DIAG_MAX_FILES 20
#define SB_DIAG_MAX_TOTAL_BYTES (2 * 1024 * 1024)

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_begun = 0;
static int g_fd = -1;
static long g_bytesWritten = 0;
static int g_capLogged = 0;
static char g_dir[PATH_MAX + 64];
static char g_currentPath[PATH_MAX + 64];
static char g_currentName[256];
static char g_dlopenMarkerPath[PATH_MAX + 64];
static char g_willConnectMarkerPath[PATH_MAX + 64];

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

void SBDiagLogBeginRun(void) {
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
    // 0.2.36：willConnect 标记路径与 dlopen 标记同款。
    rc = snprintf(g_willConnectMarkerPath, sizeof(g_willConnectMarkerPath), "%s/%s", g_dir, SB_DIAG_WILLCONNECT_MARKER_NAME);
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
    pthread_mutex_unlock(&g_lock);
    char content[512];
    int n = snprintf(content, sizeof(content), "%s\n",
                     (guestBundleID && guestBundleID[0] != '\0') ? guestBundleID : "（未知）");
    if (n <= 0) {
        return;
    }
    SBDiagWriteFile(path, content, (size_t)n);
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
    pthread_mutex_unlock(&g_lock);
    (void)unlink(path);
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
