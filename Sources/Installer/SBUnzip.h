// SBUnzip.h — 最小 zip 解压（libz inflate）：只处理 stored 与 deflate，拒绝路径穿越。

#ifndef SB_UNZIP_H
#define SB_UNZIP_H

#ifdef __cplusplus
extern "C" {
#endif

// 返回码：0 为成功，其余见下。
#define SB_UNZIP_OK 0
// 打不开 zip 文件。
#define SB_UNZIP_ERR_OPEN 1
// 不是 zip 文件（找不到 End of Central Directory 记录）。
#define SB_UNZIP_ERR_BAD_ZIP 2
// 写目标文件失败（磁盘满、权限等）。
#define SB_UNZIP_ERR_WRITE 3
// 路径穿越：entry 文件名含 ".." 分量、是绝对路径、或含反斜杠。
#define SB_UNZIP_ERR_PATH_TRAVERSAL 4
// 不支持的压缩方式（stored / deflate 以外）或 ZIP64。
#define SB_UNZIP_ERR_UNSUPPORTED 5
// zip 结构损坏（中央目录、本地文件头越界、解压数据校验失败等）。
#define SB_UNZIP_ERR_CORRUPT 6

/// 解压进度回调：fraction 为 0.0 ~ 1.0（已解压字节 / 全部未压缩字节）。
/// 每个文件写完后调一次；传 NULL 表示不需要进度。
typedef void (*SBUnzipProgressCallback)(double fraction);

/// 把 zip 解压到目标目录（不存在则创建，含多级父目录）。
///
/// - Parameters:
///   - zip_path: zip 文件路径。
///   - dest_dir: 解压目标目录。
///   - progress_callback: 进度回调，可为 NULL。
/// - Returns: `SB_UNZIP_OK` 为成功，其余为上列错误码。
///   失败时已解出的部分文件会留在目标目录，调用方负责清理。
///   只处理 stored（method 0）与 deflate（method 8）；不支持 ZIP64 与加密 entry。
int sb_unzip_to(const char *zip_path, const char *dest_dir, SBUnzipProgressCallback progress_callback);

#ifdef __cplusplus
}
#endif

#endif // SB_UNZIP_H
