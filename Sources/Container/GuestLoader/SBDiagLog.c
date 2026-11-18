// SBDiagLog.c — 启动诊断日志：纯 C 实现，不依赖 Foundation。
//
// 0.2.4 新增：0.2.3 的闪退修完真机还在崩，根因靠猜查不出来。
// 从此每次启动的每一步都实时写盘刷盘，崩了最后一步还在；
// 下次启动认得出上次崩了，把那份日志留下来，设置页能看到、能分享。
//
// 安全：本文件所有函数永不崩、不抛错、不弹框——任何失败都静默丢弃。
// 路径在 BeginRun 时一次算好并缓存（之后客 App 启动会改 HOME 环境变量，
// 缓存的路径不受影响）。写操作一把互斥锁串行化，每行 write + fsync。
#include "SBDiagLog.h"

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
#define SB_DIAG_MAX_BYTES (256 * 1024)
#define SB_DIAG_READ_CAP (SB_DIAG_MAX_BYTES + 1024)

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_begun = 0;
static int g_fd = -1;
static long g_bytesWritten = 0;
static char g_dir[PATH_MAX + 64];
static char g_currentPath[PATH_MAX + 64];
static char g_previousPath[PATH_MAX + 64];
static char g_crashedPath[PATH_MAX + 64];

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
    int rc = snprintf(g_dir, sizeof(g_dir), "%s/Documents/DiagLogs", home);
    if (rc < 0 || (size_t)rc >= sizeof(g_dir)) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    rc = snprintf(g_currentPath, sizeof(g_currentPath), "%s/SBStartupLog-current.txt", g_dir);
    if (rc < 0 || (size_t)rc >= sizeof(g_currentPath)) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    rc = snprintf(g_previousPath, sizeof(g_previousPath), "%s/SBStartupLog-previous.txt", g_dir);
    if (rc < 0 || (size_t)rc >= sizeof(g_previousPath)) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    rc = snprintf(g_crashedPath, sizeof(g_crashedPath), "%s/SBStartupLog-crashed.txt", g_dir);
    if (rc < 0 || (size_t)rc >= sizeof(g_crashedPath)) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    // 上一级 Documents 不一定存在（如测试沙盒）：先建它再建 DiagLogs。
    // 设备上容器目录本就存在，两次 mkdir 都是空操作。
    {
        char docsDir[PATH_MAX + 64];
        int docsRc = snprintf(docsDir, sizeof(docsDir), "%s/Documents", home);
        if (docsRc > 0 && (size_t)docsRc < sizeof(docsDir)) {
            (void)mkdir(docsDir, 0755);
            (void)mkdir(g_dir, 0755);
        }
    }
    size_t prevLen = 0;
    char *prev = SBDiagReadFile(g_currentPath, &prevLen);
    if (prev && prevLen > 0) {
        if (strstr(prev, SB_DIAG_MARKER) == NULL) {
            // 上次没写完成标记：启动中途崩了，留档。
            SBDiagWriteFile(g_crashedPath, prev, prevLen);
        } else {
            // 上次正常完成：旧的崩溃记录已过时，清掉。
            (void)unlink(g_crashedPath);
        }
        SBDiagWriteFile(g_previousPath, prev, prevLen);
        free(prev);
    } else {
        free(prev);
    }
    g_fd = open(g_currentPath, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
    g_bytesWritten = 0;
    pthread_mutex_unlock(&g_lock);
    SBDiagLogLine("进程启动");
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
    if (!g_begun || g_fd < 0 || g_bytesWritten >= SB_DIAG_MAX_BYTES) {
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

char *SBDiagLogLatestText(void) {
    pthread_mutex_lock(&g_lock);
    char *text = NULL;
    if (g_crashedPath[0] != '\0') {
        text = SBDiagReadFile(g_crashedPath, NULL);
    }
    if (!text && g_previousPath[0] != '\0') {
        text = SBDiagReadFile(g_previousPath, NULL);
    }
    if (!text && g_currentPath[0] != '\0') {
        text = SBDiagReadFile(g_currentPath, NULL);
    }
    pthread_mutex_unlock(&g_lock);
    return text;
}

int SBDiagLogHasCrashedLog(void) {
    pthread_mutex_lock(&g_lock);
    int has = (g_crashedPath[0] != '\0') && (access(g_crashedPath, F_OK) == 0);
    pthread_mutex_unlock(&g_lock);
    return has;
}
