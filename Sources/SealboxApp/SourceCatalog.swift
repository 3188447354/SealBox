import Foundation

// Software source catalog (0.1.4): the 27 apps from
// ~/workspace/your_files/seal-source-app-order.md (2026-11-11, MJ 定六类).
// Names, intros, versions, dates and download URLs are copied verbatim
// from that file's tables. The pinned per-version links are used (not the
// /latest/ links), so each URL matches the version and date listed with it.
// No networking happens here; downloads run through DownloadManager
// (SourceView.swift).

/// The six source categories, in display order.
enum SourceCategory: String, CaseIterable {
    case all = "全部"
    case apps = "应用"
    case games = "游戏"
    case media = "影音"
    case tools = "工具"
    case plugins = "插件"
    case troll = "巨魔"
}

/// One app in the software source.
struct SourceApp: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let intro: String
    let version: String
    let date: String
    let url: URL
    let category: SourceCategory
}

/// The full catalog, in the order file's order.
enum SourceCatalog {
    static let all: [SourceApp] = [
        // MARK: - 游戏

        SourceApp(
            name: "Delta",
            intro: "任天堂模拟器，NES/SNES/N64/GB/GBA/DS",
            version: "v1.6",
            date: "2024-07-11",
            url: URL(string: "https://github.com/rileytestut/Delta/releases/download/v1.6/Delta_1_6.ipa")!,
            category: .games
        ),
        SourceApp(
            name: "PPSSPP",
            intro: "PSP 模拟器",
            version: "v1.20.4",
            date: "2026-05-16",
            url: URL(string: "https://github.com/hrydgard/ppsspp/releases/download/v1.20.4/PPSSPP-iOS-v1.20.4.ipa")!,
            category: .games
        ),
        SourceApp(
            name: "Provenance",
            intro: "60 多个机种的复古模拟器，NES/SNES/N64/世嘉/索尼",
            version: "3.3.0",
            date: "2026-03-14",
            url: URL(string: "https://github.com/Provenance-EMU/Provenance/releases/download/3.3.0/Provenance-3.3.0-iOS.ipa")!,
            category: .games
        ),
        SourceApp(
            name: "DevilutionX",
            intro: "暗黑破坏神 1 引擎移植，支持联机",
            version: "1.5.5",
            date: "2025-10-30",
            url: URL(string: "https://github.com/diasurgical/DevilutionX/releases/download/1.5.5/devilutionx-iOS.ipa")!,
            category: .games
        ),
        SourceApp(
            name: "VCMI",
            intro: "英雄无敌 3 引擎移植",
            version: "1.7.5",
            date: "2026-08-15",
            url: URL(string: "https://github.com/vcmi/vcmi/releases/download/1.7.5/VCMI-iOS.ipa")!,
            category: .games
        ),
        SourceApp(
            name: "iNDS",
            intro: "任天堂 DS 模拟器",
            version: "v1.10.8",
            date: "2021-03-01",
            url: URL(string: "https://github.com/iNDS-Team/iNDS/releases/download/v1.10.8/iNDS.ipa")!,
            category: .games
        ),

        // MARK: - 影音

        SourceApp(
            name: "Yattee",
            intro: "无广告 YouTube 播放器（走 Invidious/Piped，不用谷歌账号）",
            version: "v1.5.1",
            date: "2024-01-28",
            url: URL(string: "https://github.com/yattee/yattee/releases/download/v1.5.1/Yattee-1.5.1-iOS.ipa")!,
            category: .media
        ),
        SourceApp(
            name: "Spotube",
            intro: "音乐播放器，不用 Spotify 会员",
            version: "v6.0.0",
            date: "2026-11-10",
            url: URL(string: "https://github.com/team-spotube/spotube/releases/download/v6.0.0/Spotube-ios.ipa")!,
            category: .media
        ),
        SourceApp(
            name: "Rivulet",
            intro: "Apple TV 应用，iOS 端",
            version: "v1.3.1-129",
            date: "2026-11-15",
            url: URL(string: "https://github.com/l984-451/Rivulet/releases/download/v1.3.1-129/Rivulet.ipa")!,
            category: .media
        ),

        // MARK: - 工具

        SourceApp(
            name: "GestaltX",
            intro: "iOS 27.x MobileGestalt 编辑器",
            version: "v1.1.1",
            date: "2026-11-13",
            url: URL(string: "https://github.com/huamidev/GestaltX/releases/download/v1.1.1/GestaltX_1.1.1.ipa")!,
            category: .tools
        ),
        SourceApp(
            name: "Erosion-CN",
            intro: "MobileGestalt 工具箱，中文",
            version: "v1.0.3",
            date: "2026-11-17",
            url: URL(string: "https://github.com/Kianuni/Erosion-CN/releases/download/v1.0.3/Erosion_v1.0.3_Bilingual.ipa")!,
            category: .tools
        ),
        SourceApp(
            name: "Hiddify",
            intro: "代理客户端",
            version: "v5.5.5",
            date: "2026-11-04",
            url: URL(string: "https://github.com/hiddify/hiddify-app/releases/download/v5.5.5/Hiddify-iOS.ipa")!,
            category: .tools
        ),
        SourceApp(
            name: "StikDebug",
            intro: "JIT 调试启动器，UTM、Henge 这类要 JIT 的应用靠它",
            version: "3.2.2",
            date: "2026-11-08",
            url: URL(string: "https://github.com/StikDebug/StikDebug/releases/download/3.2.2/StikDebug-3.2.2.ipa")!,
            category: .tools
        ),
        SourceApp(
            name: "YumEdit",
            intro: "Siri AI 开启器（未签名 IPA）",
            version: "1.3.1",
            date: "2026-11-13",
            url: URL(string: "https://github.com/H4CNPE/YumEdit/releases/download/v1.3.1/YumEdit-1.3.1-b17-unsigned.ipa")!,
            category: .tools
        ),
        SourceApp(
            name: "iTorrent",
            intro: "BT 下载器",
            version: "v2.2.0-1",
            date: "2026-07-19",
            url: URL(string: "https://github.com/XITRIX/iTorrent/releases/download/v2.2.0-1/iTorrent.ipa")!,
            category: .tools
        ),
        SourceApp(
            name: "WQFiles",
            intro: "worse_query 文件浏览器，免越狱",
            version: "v0.9.17",
            date: "2026-11-17",
            url: URL(string: "https://github.com/kolbicz/WQFiles/releases/download/v0.9.17/WQFiles.ipa")!,
            category: .tools
        ),
        SourceApp(
            name: "Henge",
            intro: "iPhone 上跑 macOS 27",
            version: "0.3",
            date: "2026-11-10",
            url: URL(string: "https://github.com/Leviidev/Henge/releases/download/0.3/Henge.ipa")!,
            category: .tools
        ),
        SourceApp(
            name: "UTM",
            intro: "iOS 虚拟机，能跑 Windows、Linux 和游戏",
            version: "v5.0.9",
            date: "2026-11-16",
            url: URL(string: "https://github.com/utmapp/UTM/releases/download/v5.0.9/UTM.ipa")!,
            category: .tools
        ),
        SourceApp(
            name: "LBox",
            intro: "LiveContainer 伴侣，浏览/安装 IPA（需配合 LiveContainer 用）",
            version: "v1.2",
            date: "2025-12-08",
            url: URL(string: "https://github.com/Lolendor/LBox/releases/download/v1.2/LBox.ipa")!,
            category: .tools
        ),

        // MARK: - 应用

        SourceApp(
            name: "Thunder",
            intro: "Lemmy 客户端",
            version: "0.8.6",
            date: "2026-01-07",
            url: URL(string: "https://github.com/thunder-app/thunder/releases/download/0.8.6/thunder-v0.8.6.ipa")!,
            category: .apps
        ),
        SourceApp(
            name: "Voyager",
            intro: "Lemmy 客户端",
            version: "2.49.1",
            date: "2026-09-13",
            url: URL(string: "https://github.com/aeharding/voyager/releases/download/2.49.1/Voyager-iOS-2.49.1.ipa")!,
            category: .apps
        ),
        SourceApp(
            name: "BHTwitter",
            intro: "推特增强版（去广告、4K 上传、语音帖）",
            version: "4.4",
            date: "2025-05-13",
            url: URL(string: "https://github.com/BandarHL/BHTwitter/releases/download/4.4/BHTwitter-sideloaded.ipa")!,
            category: .apps
        ),

        // MARK: - 插件

        SourceApp(
            name: "Misaka",
            intro: "iOS 自定义工具（改图标主题等）",
            version: "8.2.4",
            date: "2024-01-20",
            url: URL(string: "https://github.com/straight-tamago/misaka/releases/download/8.2.4/misaka-v8.2.4.ipa")!,
            category: .plugins
        ),
        SourceApp(
            name: "Cowabunga",
            intro: "iOS 自定义工具（改运营商文字、图标等）",
            version: "v10.3.2",
            date: "2023-05-29",
            url: URL(string: "https://github.com/leminlimez/Cowabunga/releases/download/v10.3.2/Cowabunga.ipa")!,
            category: .plugins
        ),

        // MARK: - 巨魔

        SourceApp(
            name: "TrollRecorder",
            intro: "通话录音（.tipa，只能 TrollStore 装）",
            version: "v4.7.5-3677",
            date: "2026-10-12",
            url: URL(string: "https://github.com/Lessica/TrollRecorder/releases/download/v4.7.5-3677/TRApp_4.7.5-3677.tipa")!,
            category: .troll
        ),
        SourceApp(
            name: "TrollInstallerX",
            intro: "TrollStore 安装器（iOS 15–16）",
            version: "1.0.3",
            date: "2024-09-12",
            url: URL(string: "https://github.com/alfiecg24/TrollInstallerX/releases/download/1.0.3/TrollInstallerX.ipa")!,
            category: .troll
        ),
        SourceApp(
            name: "Dopamine",
            intro: "越狱工具（iOS 15–17，含 17.6+ 修复）",
            version: "3.0.13",
            date: "2026-11-03",
            url: URL(string: "https://github.com/opa334/Dopamine/releases/download/3.0.13/Dopamine.ipa")!,
            category: .troll
        ),
    ]
}
