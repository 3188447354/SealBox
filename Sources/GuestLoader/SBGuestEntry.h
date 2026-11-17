// SBGuestEntry.h — 客 App 入口：读 LC_MAIN 的 entryoff、dlopen 客可执行、
// 取镜像内运行地址、32 位检测。失败返回 NO 并带中文原因（阶段：加载客 App）。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 读 Mach-O（薄包或 fat 包，取 arm64/arm64e 切片）的 LC_MAIN，返回 entryoff。
BOOL getAppEntryPoint(NSString *machOPath, uint64_t *entryoffOut, NSError **error);

/// dlopen 客可执行（RTLD_LAZY | RTLD_GLOBAL | RTLD_FIRST）。
/// 失败返回 NULL，error 为 dlerror 翻译成的中文错；iOS 27 上段数不匹配时给专门文案。
void * _Nullable dlopenGuest(NSString *path, NSError **error);

/// 该 Mach-O 是不是 32 位（cputype 非 arm64）。读不到文件头时返回 NO（交给后一步报错）。
BOOL is32BitMachOAtPath(NSString *path);

/// 把镜像内的文件偏移换算成当前进程里的运行地址
///（镜像头地址 + vmaddr_slide + fileOffset）。找不到镜像返回 NO。
BOOL runtimeAddressForImageAtPath(NSString *imagePath,
                                  uint64_t fileOffset,
                                  uintptr_t *addressOut,
                                  NSError **error);

NS_ASSUME_NONNULL_END
