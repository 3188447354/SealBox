// SBDocumentPickerHook.m — DocumentPicker 基础 swizzle。
// LC 同款（TweakLoader/DocumentPicker.m，NSFMGuestHooksInit 里不依赖
// doSymlinkInbox / fixFilePickerNew 的部分）：
//   ① UIDocumentPickerViewController initForOpeningContentTypes:asCopy:
//      ／ initWithDocumentTypes:inMode: ——类型统一换成
//      [UTTypeItem, UTTypeFolder]（客声明的自定义类型在宿主进程里可能
//      不存在，Picker 会空；只选文件夹时还会闪退）；initWithDocumentTypes:
//      按 LC 原样转发到 initForOpeningContentTypes:asCopy:
//      （mode == 1 ? NO : YES）；
//   ② UIDocumentBrowserViewController initForOpeningContentTypes: 同款；
//   ③ UTType.typeWithIdentifier: ——查不到时 fallback
//      exportedTypeWithIdentifier: 再 importedTypeWithIdentifier:
//      （直接创建类型，不经 Info.plist 的 declaration status）。
// 不做（LC 里门控在 doSymlinkInbox / fixFilePickerNew，默认 NO）：
//   startAccessingSecurityScopedResource、setAllowsMultipleSelection、
//   DOCConfiguration.setHostIdentifier:。
@import UIKit;
@import UniformTypeIdentifiers;
#import <objc/runtime.h>

#import "SBDocumentPickerHook.h"

@interface UIDocumentPickerViewController (SBGuestDocumentPicker)
- (instancetype)sb_guest_initForOpeningContentTypes:(NSArray<UTType *> *)contentTypes asCopy:(BOOL)asCopy;
- (instancetype)sb_guest_initWithDocumentTypes:(NSArray<UTType *> *)contentTypes inMode:(NSUInteger)mode;
@end

@interface UIDocumentBrowserViewController (SBGuestDocumentPicker)
- (instancetype)sb_guest_initForOpeningContentTypes:(NSArray<UTType *> *)contentTypes;
@end

@interface UTType (SBGuestDocumentPicker)
+ (instancetype)sb_guest_typeWithIdentifier:(NSString *)identifier;
@end

@implementation UIDocumentPickerViewController (SBGuestDocumentPicker)

- (instancetype)sb_guest_initForOpeningContentTypes:(NSArray<UTType *> *)contentTypes asCopy:(BOOL)asCopy {
    NSArray<UTType *> *contentTypesNew = @[UTTypeItem, UTTypeFolder];
    return [self sb_guest_initForOpeningContentTypes:contentTypesNew asCopy:asCopy];
}

- (instancetype)sb_guest_initWithDocumentTypes:(NSArray<UTType *> *)contentTypes inMode:(NSUInteger)mode {
    return [self sb_guest_initForOpeningContentTypes:contentTypes asCopy:(mode == 1 ? NO : YES)];
}

@end

@implementation UIDocumentBrowserViewController (SBGuestDocumentPicker)

- (instancetype)sb_guest_initForOpeningContentTypes:(NSArray<UTType *> *)contentTypes {
    NSArray<UTType *> *contentTypesNew = @[UTTypeItem, UTTypeFolder];
    return [self sb_guest_initForOpeningContentTypes:contentTypesNew];
}

@end

@implementation UTType (SBGuestDocumentPicker)

+ (instancetype)sb_guest_typeWithIdentifier:(NSString *)identifier {
    UTType *ans = [self sb_guest_typeWithIdentifier:identifier];
    if (ans) {
        return ans;
    } else if ((ans = [UTType exportedTypeWithIdentifier:identifier])) {
        return ans;
    } else {
        return [UTType importedTypeWithIdentifier:identifier];
    }
}

@end

void SBDocumentPickerHookInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method orig, repl;
        orig = class_getInstanceMethod([UIDocumentPickerViewController class],
                                       @selector(initForOpeningContentTypes:asCopy:));
        repl = class_getInstanceMethod([UIDocumentPickerViewController class],
                                       @selector(sb_guest_initForOpeningContentTypes:asCopy:));
        if (orig && repl) {
            method_exchangeImplementations(orig, repl);
        }
        orig = class_getInstanceMethod([UIDocumentPickerViewController class],
                                       @selector(initWithDocumentTypes:inMode:));
        repl = class_getInstanceMethod([UIDocumentPickerViewController class],
                                       @selector(sb_guest_initWithDocumentTypes:inMode:));
        if (orig && repl) {
            method_exchangeImplementations(orig, repl);
        }
        orig = class_getInstanceMethod([UIDocumentBrowserViewController class],
                                       @selector(initForOpeningContentTypes:));
        repl = class_getInstanceMethod([UIDocumentBrowserViewController class],
                                       @selector(sb_guest_initForOpeningContentTypes:));
        if (orig && repl) {
            method_exchangeImplementations(orig, repl);
        }
        orig = class_getClassMethod([UTType class], @selector(typeWithIdentifier:));
        repl = class_getClassMethod([UTType class], @selector(sb_guest_typeWithIdentifier:));
        if (orig && repl) {
            method_exchangeImplementations(orig, repl);
        }
        NSLog(@"[Sealbox] DocumentPicker Hook 已安装：initForOpeningContentTypes:asCopy:／initWithDocumentTypes:inMode:／browser initForOpeningContentTypes:＋ UTType.typeWithIdentifier: 回退");
    });
}
