// SBImporter.swift — 用系统文件选择器只收 .ipa / .tipa 文件，取消时静默抛错。

import Foundation
import UIKit
import UniformTypeIdentifiers

/// IPA 导入入口：弹出系统文件选择器，只接受 .ipa / .tipa。
/// 用户取消时抛 `SBError.cancelled`，调用方应静默处理（不弹任何提示）。
public enum SBImporter {

    /// 弹出文件选择器，让用户选一个 IPA 文件。
    /// - Parameter presenter: 用来 present 选择器的视图控制器（须在主线程持有）。
    /// - Returns: 用户选中的 IPA 文件 URL（`asCopy: true`，为临时目录内的副本）。
    /// - Throws: 用户取消时抛 `SBError.cancelled`；选中的文件扩展名不是
    ///   .ipa / .tipa 时抛 `SBError.notAnIPA`。
    public static func pickIPA(presenter: UIViewController) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                // 用 filename-extension 标签构造动态类型：即使系统未注册
                // .ipa / .tipa，也能把选择器限制在这两个扩展名上。
                let ipaType = UTType(tag: "ipa", tagClass: .filenameExtension, conformingTo: .data)
                let tipaType = UTType(tag: "tipa", tagClass: .filenameExtension, conformingTo: .data)
                let contentTypes = [ipaType, tipaType].compactMap { $0 }
                let picker = UIDocumentPickerViewController(
                    forOpeningContentTypes: contentTypes.isEmpty ? [.data] : contentTypes,
                    asCopy: true
                )
                picker.allowsMultipleSelection = false

                let delegate = SBPickerDelegate()
                delegate.onPick = { url in
                    // 选择器过滤是尽力而为，收到后按扩展名再校验一次（验收 C1）。
                    if ["ipa", "tipa"].contains(url.pathExtension.lowercased()) {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: SBError.notAnIPA)
                    }
                }
                delegate.onCancel = {
                    continuation.resume(throwing: SBError.cancelled)
                }
                picker.delegate = delegate
                // delegate 属性是弱引用，用自持有保证回调前不被释放。
                delegate.keepAlive()
                presenter.present(picker, animated: true, completion: nil)
            }
        }
    }
}

/// 文件选择器的 delegate 适配器：把 delegate 回调转成一次性闭包。
/// 用 `keepAlive()` 自持有，回调完成后立即释放，避免循环引用。
private final class SBPickerDelegate: NSObject, UIDocumentPickerDelegate {

    var onPick: ((URL) -> Void)?
    var onCancel: (() -> Void)?

    private var selfRetain: SBPickerDelegate?

    func keepAlive() {
        selfRetain = self
    }

    private func releaseAlive() {
        selfRetain = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        releaseAlive()
        if let url = urls.first {
            onPick?(url)
        } else {
            onCancel?()
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        releaseAlive()
        onCancel?()
    }
}
