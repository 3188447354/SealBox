// SBGuestMachOClassList.h — 直接读客 Mach-O 的 __objc_classlist 找类，不走 ObjC 运行时（0.2.42）。
//
// 背景（调查报告 REPORT-0.2.42-investigation.md §4）：0.2.41 的
// objc_getClassList 枚举在真实调用链里虽被证伪会自死锁，但它每次点图标
// 都在主线程跑 realizeAllClasses 全量实现化（约 1400 个 dyld 镜像），
// 且 0.2.41 拆掉干净失败门后放行的 post-gate 代码卡死了手机——
// 枚举本身是否参与卡死，离线钉不死。本版改成读磁盘镜像的静态结构：
// dyld 加载后类指针已由链式修正重定向，直接读 __objc_classlist，
// 逐项读 class_ro_t 的 name 比对；归属按“只读客镜像自己的类表”判定，
// 连运行时都不碰，/var vs /private/var 路径比对问题随之消失。
// 读表失败（非常规 Mach-O 布局等）只许干净失败写明原因，绝不回落到
// 运行时枚举（objc_getClassList / NSClassFromString 不得作为取类依据）。
#ifndef SB_GUEST_MACHO_CLASS_LIST_H
#define SB_GUEST_MACHO_CLASS_LIST_H

#ifdef __cplusplus
extern "C" {
#endif

/// 扫描一只已加载镜像的 __objc_classlist，找名字是 wantedName 的类。
/// imageBase：镜像头在内存里的地址（dyld 已滑移后的 header 指针）；
/// slide：该镜像的 vmaddr slide（_dyld_get_image_vmaddr_slide）。
/// 只做内存读＋指针运算，不调任何 ObjC 运行时 API、不拿任何锁，
/// 故在 +load / +initialize / dlopen 内等任何上下文调用都安全。
/// 返回类指针（Class），没有返回 NULL。stats 可空；传了则填扫描统计
/// （扫过的类表项数、跳过的空名项、越界项）。
typedef struct {
    unsigned int classesScanned; // 扫过的类表项数
    unsigned int nullNameCount;  // 名为空的项（lazily named Swift 泛型类）
    unsigned int corruptCount;   // 越界／损坏而跳过的项
    int foundClassList;          // 该镜像确有 __objc_classlist 段
} SBGuestMachOClassScanStats;

void *SBGuestMachOClassScanImage(const void *imageBase, long slide,
                                 const char *wantedName,
                                 SBGuestMachOClassScanStats *stats);

#if defined(__APPLE__)
/// 在客镜像（主可执行＋包内已加载的 framework）的 __objc_classlist 里
/// 找名字是 className 的类。主可执行先扫，包内 framework 后扫；
/// 宿主镜像与已加载的其他客镜像一律不扫（同名类负对照靠这个保证）。
/// guestExecPath：客可执行文件路径；guestAppPath：客 .app 包路径。
/// 返回类指针（Class），没有返回 NULL。
/// failureReasonOut（可空）：结构性失败时写进静态原因串
/// （"客镜像未在 dyld 列表里"／"客镜像无 __objc_classlist 段"／
/// "类名未安装（lazily named）"等）；单纯查无此类时为 NULL。
/// 返回的串只在下次调用前有效，不要 free、不要长期持有。
void *SBGuestMachOClassNamedInGuest(const char *className,
                                    const char *guestExecPath,
                                    const char *guestAppPath,
                                    const char **failureReasonOut);
#endif

#ifdef __cplusplus
}
#endif

#endif
