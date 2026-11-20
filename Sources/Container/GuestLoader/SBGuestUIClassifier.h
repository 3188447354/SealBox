// SBGuestUIClassifier.h — 客 App 的 UI 类型分型（0.2.28）。
//
// 按磁盘 Mach-O 的符号表与链接库定客 UI 类型，记入安装记录、供启动时分流：
//   链 Flutter.framework            → Flutter（先判：Flutter 的 Runner 调
//                                      Swift 覆盖层 UIApplicationMain，单看
//                                      C 符号会漏判——0.2.29 的
//                                      “_UIApplicationMain=否”即此盲区）
//   未定义符号含 _UIApplicationMain → UIKit（ObjC main.m）
//   未定义符号含 Swift 覆盖层 UIApplicationMain
//     （_$s5UIKit17UIApplicationMain…）→ UIKit（Swift @main /
//      @UIApplicationMain 生成的 main）
//   未定义符号含 App.main（SwiftUI 协议扩展方法，
//     _$s7SwiftUI3AppPAAE4mainyyFZ）→ SwiftUI
//   其余                               → 未知
//
// 0.2.30：0.2.27 的 SBGuestImageFileReferencesUIApplicationMain 已随拦截
// 统一重绑路删除（它只在 LC_SYMTAB 里找 C 符号，Swift-main 客永远漏判）；
// 本分型器自带完整 Mach-O 解析（符号表＋链接库＋绑定风格），现加 Swift 覆盖层
// 符号一道查。
// 注意：加载命令可能带 LC_REQ_DYLD 位（0x80000000，现代 Xcode 产物如宿主
// 二进制的 0x80000034/0x80000022），比较前须掩掉（原型 0228 实证）。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SBGuestUIType) {
    SBGuestUITypeUnknown = 0,
    SBGuestUITypeUIKit = 1,
    SBGuestUITypeSwiftUI = 2,
    SBGuestUITypeFlutter = 3,
};

/// 按客可执行文件路径分型。文件读不到 / 符号表被剥掉 / 解析失败时返回 Unknown
///（调用方按未知处理，不误拦）。只读文件，不改动。
SBGuestUIType SBGuestUITypeForGuestExecutable(NSString *execPath);

/// 类型转记录用字串：@"uikit" / @"swiftui" / @"flutter" / @"unknown"。
NSString *SBGuestUITypeToString(SBGuestUIType type);

NS_ASSUME_NONNULL_END
