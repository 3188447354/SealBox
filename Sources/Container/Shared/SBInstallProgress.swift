import SwiftUI

/// 外部传入的安装进度：进度由安装方更新，本视图只展示 pill。
/// （从 087f0661 Sources/Desktop/SBDesktopView.swift 开头原样抽出；
/// Desktop 不恢复，SBAppCoordinator 引用此类，故单独立文件。）
final class SBInstallProgress: ObservableObject {
    @Published var progress: Double = 0
    @Published var label: String = ""
    @Published var isInstalling: Bool = false
}
