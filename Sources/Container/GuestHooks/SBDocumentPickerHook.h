// SBDocumentPickerHook.h — DocumentPicker 基础 swizzle。
// LC TweakLoader/DocumentPicker.m 里不依赖 doSymlinkInbox /
// fixFilePickerNew 的部分（见 .m 文件头）。
#import <Foundation/Foundation.h>

void SBDocumentPickerHookInstall(void);
