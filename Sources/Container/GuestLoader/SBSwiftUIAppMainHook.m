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

/// 元数据首字是 kind（小整数：0=Class，1=Struct，2=Enum，3=Optional，…）。
/// witness 表首字是函数指针（大地址）。首字 < 0x100 即认作元数据。
static BOOL SBIsSwiftTypeMetadata(const void *ptr) {
    if (!ptr) {
        return NO;
    }
    uintptr_t kind = *(const uintptr_t *)ptr;
    return kind < 0x100;
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
    if (!g_swiftUIHookContext) {
        // 安装时 context 恒非空；走到这里是接线错，置错并直接返回（不跳原入口）。
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
                    @"拦截 App.main：%@ 收到 App 类型元数据 %p（kind=%lu），调 Swift 嵌入",
                    bundleID, metadata,
                    (unsigned long)*(const uintptr_t *)metadata] UTF8String]);
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
