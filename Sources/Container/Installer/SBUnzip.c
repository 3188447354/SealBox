// SBUnzip.c — 最小 zip 解压实现：读中央目录定位 entry，libz inflate 解 deflate。
//
// 不依赖任何第三方解压库，只用系统 libz。解压前按中央目录校验每个文件名，
// 含 ".." 分量、绝对路径或反斜杠的 entry 直接拒绝，整包不解。

#include "SBUnzip.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

#include <zlib.h>

#define SB_UNZIP_LOCAL_HEADER_SIG 0x04034b50u
#define SB_UNZIP_CENTRAL_HEADER_SIG 0x02014b50u
#define SB_UNZIP_EOCD_SIG 0x06054b50u
#define SB_UNZIP_IO_BUFFER_SIZE 32768

static uint16_t sb_rd16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static uint32_t sb_rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// 递归建目录（mkdir -p）。已存在不报错。
static int sb_mkdir_p(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return -1;
    }
    char tmp[4096];
    size_t len = strlen(path);
    if (len >= sizeof(tmp)) {
        return -1;
    }
    memcpy(tmp, path, len + 1);
    for (char *p = tmp + 1; *p != '\0'; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
                return -1;
            }
            *p = '/';
        }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
        return -1;
    }
    return 0;
}

// 文件名安全检查：拒绝空名、绝对路径、反斜杠，以及含 ".." 分量的相对路径。
static int sb_filename_is_safe(const char *name, size_t len) {
    if (len == 0 || name[0] == '/') {
        return 0;
    }
    if (memchr(name, '\\', len) != NULL) {
        return 0;
    }
    size_t i = 0;
    while (i < len) {
        size_t j = i;
        while (j < len && name[j] != '/') {
            j++;
        }
        size_t component_len = j - i;
        if (component_len == 2 && name[i] == '.' && name[i + 1] == '.') {
            return 0;
        }
        i = j + 1;
    }
    return 1;
}

struct sb_zip_entry {
    char *name;              // 中央目录里的文件名（NUL 结尾）
    uint16_t method;         // 0 = stored，8 = deflate
    uint32_t comp_size;
    uint32_t uncomp_size;
    uint32_t local_offset;
    int is_dir;              // 文件名以 '/' 结尾
};

static void sb_free_entries(struct sb_zip_entry *entries, uint16_t count) {
    if (entries == NULL) {
        return;
    }
    for (uint16_t i = 0; i < count; i++) {
        free(entries[i].name);
    }
    free(entries);
}

// 解一个 deflate entry：从 fp 当前位置读 comp_size 字节原始 deflate 流，写到 out。
static int sb_inflate_entry(FILE *fp, uint32_t comp_size, uint32_t uncomp_size, FILE *out) {
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    if (inflateInit2(&strm, -15) != Z_OK) {
        return SB_UNZIP_ERR_CORRUPT;
    }
    uint8_t in[SB_UNZIP_IO_BUFFER_SIZE];
    uint8_t out_buffer[SB_UNZIP_IO_BUFFER_SIZE];
    uint32_t remaining = comp_size;
    uint32_t produced = 0;
    int result = SB_UNZIP_OK;
    int zret = Z_OK;
    do {
        size_t to_read = remaining < (uint32_t)sizeof(in) ? (size_t)remaining : sizeof(in);
        if (to_read == 0) {
            break;
        }
        size_t got = fread(in, 1, to_read, fp);
        if (got != to_read) {
            result = SB_UNZIP_ERR_CORRUPT;
            break;
        }
        remaining -= (uint32_t)got;
        strm.next_in = in;
        strm.avail_in = (uInt)got;
        do {
            strm.next_out = out_buffer;
            strm.avail_out = (uInt)sizeof(out_buffer);
            zret = inflate(&strm, Z_NO_FLUSH);
            if (zret != Z_OK && zret != Z_STREAM_END && zret != Z_BUF_ERROR) {
                result = SB_UNZIP_ERR_CORRUPT;
                break;
            }
            size_t have = sizeof(out_buffer) - strm.avail_out;
            if (have > 0) {
                if (fwrite(out_buffer, 1, have, out) != have) {
                    result = SB_UNZIP_ERR_WRITE;
                    break;
                }
                produced += (uint32_t)have;
            }
            if (zret == Z_STREAM_END) {
                break;
            }
        } while (strm.avail_out == 0);
        if (result != SB_UNZIP_OK) {
            break;
        }
    } while (zret != Z_STREAM_END);
    inflateEnd(&strm);
    if (result == SB_UNZIP_OK && (zret != Z_STREAM_END || produced != uncomp_size)) {
        result = SB_UNZIP_ERR_CORRUPT;
    }
    return result;
}

// 原样拷一个 stored entry。
static int sb_copy_stored_entry(FILE *fp, uint32_t comp_size, FILE *out) {
    uint8_t buffer[SB_UNZIP_IO_BUFFER_SIZE];
    uint32_t remaining = comp_size;
    while (remaining > 0) {
        size_t to_read = remaining < (uint32_t)sizeof(buffer) ? (size_t)remaining : sizeof(buffer);
        size_t got = fread(buffer, 1, to_read, fp);
        if (got != to_read) {
            return SB_UNZIP_ERR_CORRUPT;
        }
        if (fwrite(buffer, 1, got, out) != got) {
            return SB_UNZIP_ERR_WRITE;
        }
        remaining -= (uint32_t)got;
    }
    return SB_UNZIP_OK;
}

int sb_unzip_to(const char *zip_path, const char *dest_dir, SBUnzipProgressCallback progress_callback) {
    if (zip_path == NULL || dest_dir == NULL) {
        return SB_UNZIP_ERR_BAD_ZIP;
    }
    FILE *fp = fopen(zip_path, "rb");
    if (fp == NULL) {
        return SB_UNZIP_ERR_OPEN;
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return SB_UNZIP_ERR_BAD_ZIP;
    }
    long file_size_long = ftell(fp);
    if (file_size_long < 22) {
        fclose(fp);
        return SB_UNZIP_ERR_BAD_ZIP;
    }
    size_t file_size = (size_t)file_size_long;

    // ---- 找 End of Central Directory（在文件末尾 64KB + 22 字节里倒着搜）。----
    size_t scan_size = file_size < (65536 + 22) ? file_size : (65536 + 22);
    size_t scan_start = file_size - scan_size;
    uint8_t *tail = (uint8_t *)malloc(scan_size);
    if (tail == NULL) {
        fclose(fp);
        return SB_UNZIP_ERR_CORRUPT;
    }
    if (fseek(fp, (long)scan_start, SEEK_SET) != 0 ||
        fread(tail, 1, scan_size, fp) != scan_size) {
        free(tail);
        fclose(fp);
        return SB_UNZIP_ERR_BAD_ZIP;
    }
    long eocd_rel = -1;
    for (long i = (long)scan_size - 22; i >= 0; i--) {
        if (sb_rd32(tail + i) == SB_UNZIP_EOCD_SIG) {
            eocd_rel = i;
            break;
        }
    }
    if (eocd_rel < 0) {
        free(tail);
        fclose(fp);
        return SB_UNZIP_ERR_BAD_ZIP;
    }
    uint8_t *eocd = tail + eocd_rel;
    uint16_t total_entries = sb_rd16(eocd + 10);
    uint32_t cd_size = sb_rd32(eocd + 12);
    uint32_t cd_offset = sb_rd32(eocd + 16);
    free(tail);

    if (total_entries == 0xFFFF) {
        // ZIP64 的 entry 数，暂不支持。
        fclose(fp);
        return SB_UNZIP_ERR_UNSUPPORTED;
    }
    if (sb_mkdir_p(dest_dir) != 0) {
        fclose(fp);
        return SB_UNZIP_ERR_WRITE;
    }
    if (total_entries == 0) {
        fclose(fp);
        return SB_UNZIP_OK;
    }
    if ((size_t)cd_offset >= file_size || (size_t)cd_size > file_size - (size_t)cd_offset) {
        fclose(fp);
        return SB_UNZIP_ERR_BAD_ZIP;
    }

    // ---- 读中央目录，逐条解析并做安全检查（先全量检查，再解任何文件）。----
    uint8_t *cd = (uint8_t *)malloc(cd_size);
    if (cd == NULL) {
        fclose(fp);
        return SB_UNZIP_ERR_CORRUPT;
    }
    if (fseek(fp, (long)cd_offset, SEEK_SET) != 0 ||
        fread(cd, 1, cd_size, fp) != cd_size) {
        free(cd);
        fclose(fp);
        return SB_UNZIP_ERR_BAD_ZIP;
    }
    struct sb_zip_entry *entries = (struct sb_zip_entry *)calloc(total_entries, sizeof(*entries));
    if (entries == NULL) {
        free(cd);
        fclose(fp);
        return SB_UNZIP_ERR_CORRUPT;
    }
    uint64_t total_uncomp = 0;
    size_t pos = 0;
    int result = SB_UNZIP_OK;
    for (uint16_t i = 0; i < total_entries; i++) {
        if (pos + 46 > (size_t)cd_size || sb_rd32(cd + pos) != SB_UNZIP_CENTRAL_HEADER_SIG) {
            result = SB_UNZIP_ERR_CORRUPT;
            break;
        }
        uint16_t flags = sb_rd16(cd + pos + 8);
        uint16_t method = sb_rd16(cd + pos + 10);
        uint32_t comp_size = sb_rd32(cd + pos + 20);
        uint32_t uncomp_size = sb_rd32(cd + pos + 24);
        uint16_t name_len = sb_rd16(cd + pos + 28);
        uint16_t extra_len = sb_rd16(cd + pos + 30);
        uint16_t comment_len = sb_rd16(cd + pos + 32);
        uint32_t local_offset = sb_rd32(cd + pos + 42);
        if (pos + 46 + name_len + extra_len + comment_len > (size_t)cd_size) {
            result = SB_UNZIP_ERR_CORRUPT;
            break;
        }
        if (flags & 0x0001) {
            // 加密 entry，不支持。
            result = SB_UNZIP_ERR_UNSUPPORTED;
            break;
        }
        if (comp_size == UINT32_MAX || uncomp_size == UINT32_MAX) {
            // ZIP64，不支持。
            result = SB_UNZIP_ERR_UNSUPPORTED;
            break;
        }
        char *name = (char *)malloc((size_t)name_len + 1);
        if (name == NULL) {
            result = SB_UNZIP_ERR_CORRUPT;
            break;
        }
        memcpy(name, cd + pos + 46, name_len);
        name[name_len] = '\0';
        if (!sb_filename_is_safe(name, name_len)) {
            free(name);
            result = SB_UNZIP_ERR_PATH_TRAVERSAL;
            break;
        }
        entries[i].name = name;
        entries[i].method = method;
        entries[i].comp_size = comp_size;
        entries[i].uncomp_size = uncomp_size;
        entries[i].local_offset = local_offset;
        entries[i].is_dir = (name_len > 0 && name[name_len - 1] == '/');
        total_uncomp += uncomp_size;
        pos += 46 + name_len + extra_len + comment_len;
    }
    free(cd);
    if (result != SB_UNZIP_OK) {
        sb_free_entries(entries, total_entries);
        fclose(fp);
        return result;
    }

    // ---- 逐条解出：本地文件头只用来定位数据起点，大小以中央目录为准。----
    uint64_t done_uncomp = 0;
    for (uint16_t i = 0; i < total_entries; i++) {
        struct sb_zip_entry *entry = &entries[i];
        size_t full_len = strlen(dest_dir) + 1 + strlen(entry->name) + 1;
        char *full_path = (char *)malloc(full_len);
        if (full_path == NULL) {
            result = SB_UNZIP_ERR_CORRUPT;
            break;
        }
        snprintf(full_path, full_len, "%s/%s", dest_dir, entry->name);
        if (entry->is_dir) {
            if (sb_mkdir_p(full_path) != 0) {
                free(full_path);
                result = SB_UNZIP_ERR_WRITE;
                break;
            }
            free(full_path);
            continue;
        }
        // 先建好父目录。
        char *slash = strrchr(full_path, '/');
        if (slash != NULL) {
            *slash = '\0';
            if (sb_mkdir_p(full_path) != 0) {
                free(full_path);
                result = SB_UNZIP_ERR_WRITE;
                break;
            }
            *slash = '/';
        }
        if (fseek(fp, (long)entry->local_offset, SEEK_SET) != 0) {
            free(full_path);
            result = SB_UNZIP_ERR_CORRUPT;
            break;
        }
        uint8_t local_header[30];
        if (fread(local_header, 1, sizeof(local_header), fp) != sizeof(local_header) ||
            sb_rd32(local_header) != SB_UNZIP_LOCAL_HEADER_SIG) {
            free(full_path);
            result = SB_UNZIP_ERR_CORRUPT;
            break;
        }
        uint16_t lh_name_len = sb_rd16(local_header + 26);
        uint16_t lh_extra_len = sb_rd16(local_header + 28);
        long data_start = (long)entry->local_offset + 30 + lh_name_len + lh_extra_len;
        if (fseek(fp, data_start, SEEK_SET) != 0) {
            free(full_path);
            result = SB_UNZIP_ERR_CORRUPT;
            break;
        }
        FILE *out = fopen(full_path, "wb");
        if (out == NULL) {
            free(full_path);
            result = SB_UNZIP_ERR_WRITE;
            break;
        }
        if (entry->method == 0) {
            result = sb_copy_stored_entry(fp, entry->comp_size, out);
        } else if (entry->method == 8) {
            if (entry->uncomp_size == 0) {
                result = SB_UNZIP_OK; // 空文件，无 deflate 流可解。
            } else {
                result = sb_inflate_entry(fp, entry->comp_size, entry->uncomp_size, out);
            }
        } else {
            result = SB_UNZIP_ERR_UNSUPPORTED;
        }
        fclose(out);
        free(full_path);
        if (result != SB_UNZIP_OK) {
            break;
        }
        done_uncomp += entry->uncomp_size;
        if (progress_callback != NULL && total_uncomp > 0) {
            progress_callback((double)done_uncomp / (double)total_uncomp);
        }
    }

    sb_free_entries(entries, total_entries);
    fclose(fp);
    return result;
}
