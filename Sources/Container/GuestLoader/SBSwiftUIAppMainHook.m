// SBSwiftUIAppMainHook.m — SwiftUI 客的 App.main 拦截（0.2.28）。
#import "SBSwiftUIAppMainHook.h"

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdbool.h>
#import <stdint.h>
#import <string.h>

#import "SBChainedFixupRebind.h"
#import "SBDiagLog.h"
#import "SBGuestLoader.h"

// Swift 嵌入函数（SBSwiftUIEmbed.swift，@_cdecl 导出；ObjC 侧自行声明）。
extern bool SBSwiftUIEmbedApp(const void *typeMetadata,
                              SBGuestMainHookContext *context);

static const char * const SBAppMainSymbol = "_$s7SwiftUI3AppPAAE4mainyyFZ";

static SBGuestMainHookContext *g_swiftUIHookContext = nil;
static BOOL g_swiftUIHookDidActivate = NO;
static NSError *g_swiftUIHookActivationError = nil;

BOOL SBSwiftUIAppMainHookDidActivate(void) {
    return g_swiftUIHookDidActivate;
}

NSError * _Nullable SBSwiftUIAppMainHookActivationError(void) {
    return g_swiftUIHookActivationError;
}

void SBSwiftUIAppMainHookResetActivationState(void) {
    g_swiftUIHookDidActivate = NO;
    g_swiftUIHookActivationError = nil;
}

/// 元数据首字是 kind（指针大小的整数，在偏移 0 处；Swift ABI
/// docs/ABI/TypeMetadata.rst）。kind 的取值见 MetadataKind.def /
/// MetadataValues.h（不是 0/1/2/3 的序号——0.2.28 的注释写错了）：
///   Class=0x0，Struct=0x200，Enum=0x201，Optional=0x202，
///   ForeignClass=0x203，Opaque=0x300，Tuple=0x301，Function=0x302，
///   Existential=0x303，Metatype=0x304，ObjCClassWrapper=0x305，
///   ExistentialMetatype=0x306，HeapLocalVariable=0x400，
///   HeapGenericLocalVariable=0x500，ErrorObject=0x501，
///   LastEnumerated=0x7FF。
/// 枚举 kind 恒 ≤ LastEnumerated（0x7FF）；指针（isa / witness 表函数
/// 指针）恒 > 0x7FF（ABI 文档原话：isa 指针保证大于 2047）。旧检查
/// `kind < 0x100` 只认 Class（0x0）——struct App（0x200）全被拒，
/// 0.2.31 真机 Husk/STV 同因报“两个隐式参数都不是类型元数据”。
/// 名义类型（Class/Struct/Enum/Optional/ForeignClass）的 [1] 是 nominal
/// type descriptor 指针（大地址），再验一次防偶然小整数。
/// witness 表首字是函数指针（大地址），到不了这里。
/// 离线实证见 ~/workspace/tmp-sb0232verify/meta0232-verify.py
///（ALL CHECKS PASS：入口反汇编证 x0=元数据、x1=witness 表；
/// HuskApp 描述器在位；kind 值表按 MetadataKind.def）。
static BOOL SBIsSwiftTypeMetadata(const void *ptr) {
    if (!ptr) {
        return NO;
    }
    const uintptr_t *words = (const uintptr_t *)ptr;
    uintptr_t kind = words[0];
    if (kind > 0x7FF) {
        return NO;
    }
    if (kind == 0x0 || (kind >= 0x200 && kind <= 0x203)) {
        if (words[1] <= 0x7FF) {
            return NO;
        }
    }
    return YES;
}

/// 从两个隐式参数里挑出类型元数据（元数据与 witness 表顺序不定）。
/// 两个都不是时返回 NULL（调用方置错，不跳原入口）。
static const void *SBSwiftUIMetadataFromArgs(const void *arg0,
                                             const void *arg1) {
    if (SBIsSwiftTypeMetadata(arg0)) {
        return arg0;
    }
    if (SBIsSwiftTypeMetadata(arg1)) {
        return arg1;
    }
    return NULL;
}

void SBHookedAppMain(const void *arg0, const void *arg1) {
    // 0.2.31：入口第一行——钩子一旦触发必有此行（0.2.30 Husk 真机日志到
    // “跳入客 main”就断、无拦截行，无法区分“钩子没触发”与“日志丢了”。
    // 现在文件夹＋写穿保证此行若触发必落盘；无此行即钩子没触发）。
    SBDiagLogLine("拦截 App.main：钩子已触发");
    // 0.2.32：记两参数指向处的前两个字（入口传来的指针恒有效——编译器生成
    // 的分发器只传元数据与 witness 表，见 meta0232-verify.py 的入口反汇编；
    // 下版诊断靠这行确认 kind/描述器，不再只靠“是不是元数据”一句话）。
    SBDiagLogLine([[NSString stringWithFormat:
                    @"拦截 App.main：隐式参数内容 arg0=[0x%lx, 0x%lx] arg1=[0x%lx, 0x%lx]",
                    (unsigned long)(arg0 ? ((const uintptr_t *)arg0)[0] : 0),
                    (unsigned long)(arg0 ? ((const uintptr_t *)arg0)[1] : 0),
                    (unsigned long)(arg1 ? ((const uintptr_t *)arg1)[0] : 0),
                    (unsigned long)(arg1 ? ((const uintptr_t *)arg1)[1] : 0)] UTF8String]);
    if (!g_swiftUIHookContext) {
        // 安装时 context 恒非空；走到这里是接线错，置错并直接返回（不跳原入口）。
        SBDiagLogLine("拦截 App.main：钩子 context 为空（接线错），不嵌入、不跳原入口");
        g_swiftUIHookActivationError = SBGuestLoaderErrorMake(
            SBGuestLoaderErrorGuestLoadFailed, @"加载客 App",
            @"该应用是 SwiftUI 应用，暂不支持进程内启动",
            @"该应用暂不支持在虚拟机内打开，请等待后续版本");
        return;
    }
    NSString *bundleID = g_swiftUIHookContext.bundleID ?: @"未知客";
    const void *metadata = SBSwiftUIMetadataFromArgs(arg0, arg1);
    if (!metadata) {
        SBDiagLogLine([[NSString stringWithFormat:
                        @"拦截 App.main：%@ 两个隐式参数都不是类型元数据（arg0=%p arg1=%p），不嵌入",
                        bundleID, arg0, arg1] UTF8String]);
        g_swiftUIHookActivationError = SBGuestLoaderErrorMake(
            SBGuestLoaderErrorGuestLoadFailed, @"加载客 App",
            @"该应用是 SwiftUI 应用，暂不支持进程内启动",
            @"该应用暂不支持在虚拟机内打开，请等待后续版本");
        return;
    }
    SBDiagLogLine([[NSString stringWithFormat:
                    @"拦截 App.main：%@ 收到 App 类型元数据 %p（kind=0x%lx，描述器=%p），调 Swift 嵌入",
                    bundleID, metadata,
                    (unsigned long)*(const uintptr_t *)metadata,
                    (const void *)((const uintptr_t *)metadata)[1]] UTF8String]);
    BOOL ok = SBSwiftUIEmbedApp(metadata, g_swiftUIHookContext);
    if (ok) {
        g_swiftUIHookDidActivate = YES;
        SBDiagLogLine([[NSString stringWithFormat:@"拦截 App.main：%@ SwiftUI 嵌客已激活",
                        bundleID] UTF8String]);
        return;
    }
    // 嵌入失败：不调原 App.main（第二遍 runApp 必崩）；bootstrap 在 main
    // 返回后读到激活错误，按加载失败处理。
    g_swiftUIHookActivationError = SBGuestLoaderErrorMake(
        SBGuestLoaderErrorGuestLoadFailed, @"加载客 App",
        @"该应用是 SwiftUI 应用，暂不支持进程内启动",
        @"该应用暂不支持在虚拟机内打开，请等待后续版本");
    SBDiagLogLine([[NSString stringWithFormat:@"拦截 App.main：%@ Swift 嵌入失败（见上文日志），不跳原入口",
                    bundleID] UTF8String]);
}

#pragma mark - 安装

/// 按执行路径找客镜像头（SBGuestMainHook.m 同款逻辑，SwiftUI 钩子自带一份）。
static const struct mach_header *SBSwiftUIImageHeaderForExecPath(NSString *execPath) {
    const char *execPathUTF8 = [execPath UTF8String];
    if (!execPathUTF8) {
        return NULL;
    }
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strcmp(name, execPathUTF8) == 0) {
            return _dyld_get_image_header(i);
        }
    }
    NSString *execName = execPath.lastPathComponent;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && [[[NSString stringWithUTF8String:name] lastPathComponent] isEqualToString:execName]) {
            return _dyld_get_image_header(i);
        }
    }
    return NULL;
}

BOOL SBSwiftUIAppMainHookInstallForGuestImage(const struct mach_header *guestHeader,
                                              SBGuestMainHookContext *context) {
    g_swiftUIHookContext = context;
    SBSwiftUIAppMainHookResetActivationState();
    if (!guestHeader) {
        guestHeader = SBSwiftUIImageHeaderForExecPath(context.guestExecPath);
    }
    if (!guestHeader) {
        SBDiagLogLine([[NSString stringWithFormat:@"拦截 App.main：%@ 找不到客镜像头，不装拦截",
                        context.bundleID] UTF8String]);
        return NO;
    }
    BOOL ok = SBRebindGuestSymbolForImage(guestHeader, context.guestExecPath,
                                          SBAppMainSymbol,
                                          (void *)SBHookedAppMain);
    if (!ok) {
        // 具体原因见上文链式重绑诊断（符号不在 import 表里 / 无槽 / 改写失败）。
        SBDiagLogLine([[NSString stringWithFormat:@"拦截 App.main：%@ 重绑未装上（见上文链式重绑诊断），走护栏",
                        context.bundleID] UTF8String]);
        return NO;
    }
    SBDiagLogLine([[NSString stringWithFormat:@"拦截 App.main：%@ 已在客镜像重绑 App.main → SBHookedAppMain",
                    context.bundleID] UTF8String]);
    return YES;
}
