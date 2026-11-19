// dyld_cache_format.h — 最小兼容头（我们自己的接线文件，不是 LiveContainer 代码）。
//
// 背景：LiveContainer 的 LCMachOUtils.m 有一行 `#include "dyld_cache_format.h"`，
// 但该文件不在 LiveContainer 仓库里（git ls-files 无此文件；LC 工程也没有
// HEADER_SEARCH_PATHS 指向它）——它是 Apple dyld 开源工程里的头
// （dyld3/shared-cache/dyld_cache_format.h，见
// https://opensource.apple.com/source/dyld/dyld-832.7.3/dyld3/shared-cache/dyld_cache_format.h.auto.html）。
// LCMachOUtils.m 只用它里面的三个结构：
//   - struct dyld_chained_fixups_header / struct dyld_chained_starts_in_image
//     —— SDK 公开头文件 <mach-o/fixup-chains.h> 里已有，直接引用；
//   - struct dyld_cache_header —— 只在 LCGetMachOUUID 的 dyld 缓存分支里读
//     ->uuid（我们只传 Mach-O 文件头，该分支实际走不到，但编译需要类型）。
//     这里按 Apple dyld 源码的真实字段顺序只复现到 uuid 为止的前缀
//     （magic[16] + 4 个 u32 + 6 个 u64，uuid 在偏移 88 处），
//     其余字段 LCMachOUtils.m 不用，不复现。
// 若将来 SDK 自带 mach-o/dyld_cache_format.h，本文件的同名 quoted include
// 仍优先（本地目录先搜），不冲突。

#ifndef SB_DYLD_CACHE_FORMAT_H
#define SB_DYLD_CACHE_FORMAT_H

#include <mach-o/fixup-chains.h>
#include <stdint.h>

struct dyld_cache_header {
    char magic[16];                 // e.g. "dyld_v1  arm64e"
    uint32_t mappingOffset;         // file offset to first dyld_cache_mapping_info
    uint32_t mappingCount;          // number of dyld_cache_mapping_info entries
    uint32_t imagesOffset;          // file offset to first dyld_cache_image_info
    uint32_t imagesCount;           // number of dyld_cache_image_info entries
    uint64_t dyldBaseAddress;       // base address of dyld
    uint64_t codeSignatureOffset;
    uint64_t codeSignatureSize;
    uint64_t slideInfoOffset;
    uint64_t slideInfoSize;
    uint64_t localSymbolsOffset;
    uint64_t localSymbolsSize;
    uint8_t uuid[16];               // 偏移 88，与 Apple dyld 源码一致
    // 其余字段 LCMachOUtils.m 不用，不复现。
};

#endif // SB_DYLD_CACHE_FORMAT_H
