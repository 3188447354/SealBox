// SBFileManagerHook.m — 文件管理 Hook：容器路径改写。
//   ① -[NSFileManager containerURLForSecurityApplicationGroupIdentifier:]
//      返回客数据容器（客 App 自己的 App Group 在宿主进程里不存在，
//      原样返回会拿到宿主的 App Group，读错位置）；
//   ② 客镜像里对 NSHomeDirectory() 的调用重定向到客容器（HOME 环境变量
//      已被宿主改过，这里是给直接调该函数的客代码再兜一层底）。
// 0.2.25：litehook_rebind_symbol 的 replacee 参数是原函数指针，不是符号名
// 字符串（见 SBSecItemHook.m 文件头同款说明）——0.2.24 之前传 "_NSHomeDirectory"
// 字符串是静默 no-op；本版改传 dlsym 到的 g_orig_NSHomeDirectory。
// 其余目录（Documents/Caches 等）靠宿主改写 HOME 自然落进客容器，不另 Hook。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdlib.h>

#import "SBGuestHookUtils.h"
#import "litehook.h"

@interface NSFileManager (SBGuestHook)
- (nullable NSURL *)sb_guest_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier;
@end

@implementation NSFileManager (SBGuestHook)

- (nullable NSURL *)sb_guest_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    const char *container = getenv("SB_GUEST_CONTAINER_PATH");
    if (container && container[0] != '\0') {
        return [NSURL fileURLWithPath:[NSString stringWithUTF8String:container]];
    }
    // 交换后调到这里就是原实现。
    return [self sb_guest_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
}

@end

static NSString *(*g_orig_NSHomeDirectory)(void) = NULL;

static NSString *SBHookedNSHomeDirectory(void) {
    const char *container = getenv("SB_GUEST_CONTAINER_PATH");
    if (container && container[0] != '\0') {
        return [NSString stringWithUTF8String:container];
    }
    if (g_orig_NSHomeDirectory) {
        return g_orig_NSHomeDirectory();
    }
    return nil;
}

void SBFileManagerHookInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method orig = class_getInstanceMethod([NSFileManager class],
                                              @selector(containerURLForSecurityApplicationGroupIdentifier:));
        Method repl = class_getInstanceMethod([NSFileManager class],
                                              @selector(sb_guest_containerURLForSecurityApplicationGroupIdentifier:));
        if (orig && repl) {
            method_exchangeImplementations(orig, repl);
        }
        const struct mach_header *guestHeader = SBGuestImageHeader();
        if (!guestHeader) {
            NSLog(@"[Sealbox] NSHomeDirectory Hook 未安装：找不到客可执行镜像");
            return;
        }
        g_orig_NSHomeDirectory = (NSString *(*)(void))dlsym(RTLD_DEFAULT, "NSHomeDirectory");
        if (g_orig_NSHomeDirectory) {
            litehook_rebind_symbol(guestHeader, (void *)g_orig_NSHomeDirectory, (void *)SBHookedNSHomeDirectory, NULL);
            NSLog(@"[Sealbox] NSHomeDirectory Hook 已安装（0.2.25 函数指针传法）");
        }
    });
}
