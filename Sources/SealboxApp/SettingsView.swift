import SwiftUI
import AVFoundation
import AudioToolbox
import PhotosUI
import UniformTypeIdentifiers

// Settings app (0.1.4): full settings page with 12 real sub-pages.
// Navigation: NavigationStack with large title + search; no back button
// (return home via the root view's bottom swipe-up gesture).
// All toggles/sliders persist via @AppStorage with the fixed vm.settings.* keys.
// SwiftUI only, no networking, no App Group, no LiveContainer/SealBox code.

/// The 12 reachable sub-pages of Settings.
private enum SettingsDestination: String, Hashable, CaseIterable {
    case wifi = "无线局域网"
    case bluetooth = "蓝牙"
    case cellular = "蜂窝网络"
    case hotspot = "个人热点"
    case general = "通用"
    case about = "关于本机"
    case display = "显示与亮度"
    case wallpaper = "墙纸"
    case sounds = "声音与触感"
    case faceID = "面容 ID 与密码"
    case battery = "电池"
    case privacy = "隐私与安全性"
    /// 0.2.37：虚拟机用户（Apple ID 卡片样式）——点设置页顶部的账号卡片进入。
    case account = "虚拟机用户"

    var icon: String {
        switch self {
        case .wifi: return "wifi"
        case .bluetooth: return "bluetooth"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .hotspot: return "personalhotspot"
        case .general: return "gear"
        case .about: return "info.circle"
        case .display: return "sun.max.fill"
        case .wallpaper: return "photo"
        case .sounds: return "speaker.wave.3.fill"
        case .faceID: return "faceid"
        case .battery: return "battery.100"
        case .privacy: return "hand.raised.fill"
        case .account: return "person.crop.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .wifi: return .blue
        case .bluetooth: return .blue
        case .cellular: return .green
        case .hotspot: return .green
        case .general: return .gray
        case .about: return .gray
        case .display: return .blue
        case .wallpaper: return .cyan
        case .sounds: return .pink
        case .faceID: return .green
        case .battery: return .green
        case .privacy: return .blue
        case .account: return .gray
        }
    }
}

struct SettingsView: View {
    @State private var searchText = ""
    @AppStorage("vm.settings.wifiNetwork") private var wifiNetwork = "SealBox-5G"
    /// 0.2.37：账号卡片用的证书信息（叶子证书里取真实 Apple ID）与自选头像。
    @State private var certInfo: SBCertificate.SBCertificateInfo?
    /// 0.2.38：证书版本号——虚拟机用户页导入／删除证书后 +1，设置页监听到即重读卡片。
    @AppStorage("vm.settings.certificate.customVersion") private var certVersion = 0
    @AppStorage("vm.settings.avatar.customVersion") private var avatarVersion = 0
    @State private var avatarImage: UIImage?

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    private var searchResults: [SettingsDestination] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return SettingsDestination.allCases.filter { $0.rawValue.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    searchList
                } else {
                    groupedList
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "搜索")
            .navigationDestination(for: SettingsDestination.self) { destination in
                subPage(destination)
            }
            // 0.2.37：账号卡片的数据（证书里的真实 Apple ID）与自选头像进页时读一次；
            // 头像在账号页换完后版本号变，这里重读、卡片同步换。
            .task {
                certInfo = await SBCertificate.certificateInfo()
                avatarImage = VMUserAvatar.loadImage()
            }
            .onChange(of: avatarVersion) { _ in
                avatarImage = VMUserAvatar.loadImage()
            }
            .onChange(of: certVersion) { _ in
                Task { certInfo = await SBCertificate.certificateInfo() }
            }
        }
    }

    // MARK: - Main lists

    private var groupedList: some View {
        List {
            // Account card — 0.2.37：按 iOS 设置页 Apple ID 卡片的样子显示：
            // 名字＋邮箱取自导入证书的叶子证书（免费号 CN 就是 Apple ID 邮箱），
            // 取不到的不编、如实显示已有的；头像是用户自选图、没选时默认头像。
            // 点卡片进“虚拟机用户”页（换头像/恢复默认都在那页）。
            Section {
                NavigationLink(value: SettingsDestination.account) {
                    HStack(spacing: 14) {
                        if let avatarImage {
                            Image(uiImage: avatarImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .frame(width: 56, height: 56)
                                .foregroundStyle(.gray)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(accountDisplayName)
                                .font(.title3)
                            Text(accountSecondaryLine)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            // Group 1: connectivity
            Section {
                NavigationLink(value: SettingsDestination.wifi) {
                    SettingsRow(destination: .wifi, detail: wifiNetwork)
                }
                NavigationLink(value: SettingsDestination.bluetooth) {
                    SettingsRow(destination: .bluetooth)
                }
                NavigationLink(value: SettingsDestination.cellular) {
                    SettingsRow(destination: .cellular)
                }
                NavigationLink(value: SettingsDestination.hotspot) {
                    SettingsRow(destination: .hotspot)
                }
            }

            // Group 2: system
            Section {
                NavigationLink(value: SettingsDestination.general) {
                    SettingsRow(destination: .general)
                }
                NavigationLink(value: SettingsDestination.display) {
                    SettingsRow(destination: .display)
                }
                NavigationLink(value: SettingsDestination.wallpaper) {
                    SettingsRow(destination: .wallpaper)
                }
                NavigationLink(value: SettingsDestination.sounds) {
                    SettingsRow(destination: .sounds)
                }
                NavigationLink(value: SettingsDestination.faceID) {
                    SettingsRow(destination: .faceID)
                }
                NavigationLink(value: SettingsDestination.battery) {
                    SettingsRow(destination: .battery)
                }
                NavigationLink(value: SettingsDestination.privacy) {
                    SettingsRow(destination: .privacy)
                }
            }

            // 启动诊断日志（0.2.4）：上次启动是否崩了 + 查看全文。
            StartupDiagLogSection()
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }

    /// 账号卡片主行：证书里的人名（付费号）→ 邮箱（免费号 CN 即邮箱）→ 默认“虚拟机用户”。
    private var accountDisplayName: String {
        certInfo?.accountName ?? certInfo?.accountEmail ?? "虚拟机用户"
    }

    /// 账号卡片副行：有人名时显示邮箱；只有邮箱时显示 Team ID；无证书时“未登录”。
    private var accountSecondaryLine: String {
        if certInfo?.accountName != nil {
            return certInfo?.accountEmail
                ?? (certInfo?.teamID.map { "Team ID \($0)" } ?? "已导入证书")
        }
        if certInfo?.accountEmail != nil {
            return certInfo?.teamID.map { "Team ID \($0)" } ?? "已导入证书"
        }
        return certInfo == nil ? "未登录" : "已导入证书"
    }

    /// Flat results while searching; tapping one opens its sub-page.
    private var searchList: some View {
        List {
            ForEach(searchResults, id: \.self) { destination in
                NavigationLink(value: destination) {
                    SettingsRow(destination: destination, detail: destination == .wifi ? wifiNetwork : nil)
                }
            }
            if searchResults.isEmpty {
                Text("没有找到结果")
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }

    // MARK: - Sub-pages

    @ViewBuilder
    private func subPage(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .wifi: WiFiSettingsView()
        case .bluetooth: BluetoothSettingsView()
        case .cellular: CellularSettingsView()
        case .hotspot: HotspotSettingsView()
        case .general: GeneralSettingsView()
        case .about: AboutSettingsView()
        case .display: DisplaySettingsView()
        case .wallpaper: WallpaperSettingsView()
        case .sounds: SoundsSettingsView()
        case .faceID: FaceIDSettingsView()
        case .battery: BatterySettingsView()
        case .privacy: PrivacySettingsView()
        case .account: AccountSettingsView()
        }
    }
}

// MARK: - Shared row views

/// iOS-style settings row: colored icon + title + optional detail text.
private struct SettingsRow: View {
    let destination: SettingsDestination
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: destination.icon, color: destination.iconColor)
            Text(destination.rawValue)
                .foregroundStyle(.primary)
            Spacer()
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color, in: RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - 1. 无线局域网

private struct WiFiSettingsView: View {
    @AppStorage("vm.settings.wifi") private var wifiOn = true
    @AppStorage("vm.settings.wifiNetwork") private var wifiNetwork = "SealBox-5G"

    private let networks = ["SealBox-5G", "SealBox-2.4G", "Home-WiFi", "CoffeeShop-Guest"]

    var body: some View {
        List {
            Section {
                Toggle("无线局域网", isOn: $wifiOn)
            }
            if wifiOn {
                Section("选取网络") {
                    ForEach(networks, id: \.self) { name in
                        Button {
                            wifiNetwork = name
                        } label: {
                            HStack {
                                Text(name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if name == wifiNetwork {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                                Image(systemName: "wifi")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("无线局域网")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 2. 蓝牙

/// No fake device list: the VM has no real Bluetooth scan source, so it
/// shows only the switch and an honest empty state.
private struct BluetoothSettingsView: View {
    @AppStorage("vm.settings.bluetooth") private var bluetoothOn = true

    var body: some View {
        List {
            Section {
                Toggle("蓝牙", isOn: $bluetoothOn)
            }
            if bluetoothOn {
                Section {
                    Text("没有已配对的设备")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("我的设备")
                } footer: {
                    Text("虚拟机内没有真实蓝牙扫描，不显示设备列表。")
                }
            }
        }
        .navigationTitle("蓝牙")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 3. 蜂窝网络

/// Traffic numbers deleted (0.1.7): the VM has no real carrier usage
/// source, so no usage figures are shown at all.
private struct CellularSettingsView: View {
    @AppStorage("vm.settings.cellular") private var cellularOn = true

    var body: some View {
        List {
            Section {
                Toggle("蜂窝数据", isOn: $cellularOn)
            } footer: {
                Text("虚拟机内没有真实流量统计，不显示用量数字。")
            }
        }
        .navigationTitle("蜂窝网络")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 4. 个人热点

/// The password is a VM-local setting value: tap the row to copy it,
/// or regenerate a new one. The settings page and this page read the
/// same @AppStorage key, so they always agree.
private struct HotspotSettingsView: View {
    @AppStorage("vm.settings.hotspot") private var hotspotOn = false
    @AppStorage("vm.settings.hotspotPassword") private var hotspotPassword = "SealBox1234"
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Toggle("允许其他人加入", isOn: $hotspotOn)
            }
            Section {
                Button {
                    UIPasteboard.general.string = hotspotPassword
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    HStack {
                        Text("无线局域网密码")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(hotspotPassword)
                            .foregroundStyle(.secondary)
                        if copied {
                            Text("已复制")
                                .font(.footnote)
                                .foregroundStyle(.green)
                        }
                    }
                }
                Button("重新生成密码") {
                    hotspotPassword = VMPasswords.randomHotspotPassword()
                    copied = false
                }
            } footer: {
                Text("虚拟机内不真的开启热点，这里只保存开关与密码；点一下密码可复制到剪贴板。")
            }
        }
        .navigationTitle("个人热点")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 5. 通用

/// Every row opens a working sub-page. Values shown here are the VM's own
/// stored settings or real system/disk measurements — no invented numbers.
private struct GeneralSettingsView: View {
    @AppStorage("vm.settings.backgroundRefresh") private var backgroundRefresh = true
    @AppStorage("vm.settings.keyboard") private var keyboard = "简体拼音"
    @AppStorage("vm.settings.language") private var language = "简体中文"
    @AppStorage("vm.settings.autoDateTime") private var autoDateTime = true

    var body: some View {
        List {
            Section {
                NavigationLink("关于本机", value: SettingsDestination.about)
                NavigationLink {
                    SoftwareUpdateView()
                } label: {
                    LabeledRow(label: "软件更新", value: VMDevice.appVersionString)
                }
                NavigationLink {
                    StorageView()
                } label: {
                    LabeledRow(label: "储存空间", value: "可用 \(VMFiles.diskSpace().available)")
                }
                NavigationLink {
                    BackgroundRefreshView()
                } label: {
                    LabeledRow(label: "后台 App 刷新", value: backgroundRefresh ? "开" : "关")
                }
                NavigationLink {
                    DateTimeView()
                } label: {
                    LabeledRow(label: "日期与时间", value: autoDateTime ? "自动设置" : "手动")
                }
                NavigationLink {
                    KeyboardView()
                } label: {
                    LabeledRow(label: "键盘", value: keyboard)
                }
                NavigationLink {
                    LanguageView()
                } label: {
                    LabeledRow(label: "语言与地区", value: language)
                }
            }
        }
        .navigationTitle("通用")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 5a. 软件更新

/// Checks only this VM app's own version. The version shown is the app's
/// real Bundle version — never an invented iOS version number.
/// 0.2.1：删掉了假的“检查更新”按钮——它只睡 1.2 秒就报“已是最新版本”，
/// 什么都没检查。没有可用的更新检查服务，不装样子。
private struct SoftwareUpdateView: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Text("虚拟机版本")
                    Spacer()
                    Text(VMDevice.appVersionString)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("没有可用的更新检查服务；新版本随 IPA 文件发放。")
            }
        }
        .navigationTitle("软件更新")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 5b. 储存空间

/// Real disk numbers from FileManager + the real size of Documents/IPAs
/// and the real count of installed apps.
private struct StorageView: View {
    // 只为订阅 SBStore：装完/删完后“已装应用”计数要刷新。
    @ObservedObject private var store = SBStore.shared

    var body: some View {
        let space = VMFiles.diskSpace()
        List {
            Section {
                LabeledRow(label: "总容量", value: space.total)
                LabeledRow(label: "可用", value: space.available)
            } header: {
                Text("本机储存空间")
            } footer: {
                Text("以上为本机真实磁盘空间，由系统读取。")
            }
            Section("应用下载") {
                LabeledRow(label: "已下载 IPA 大小", value: VMFiles.ipasDirectorySizeString())
                LabeledRow(label: "已装应用", value: "\(store.installedApps.count) 个")
            }
        }
        .navigationTitle("储存空间")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 5c. 后台 App 刷新

private struct BackgroundRefreshView: View {
    @AppStorage("vm.settings.backgroundRefresh") private var backgroundRefresh = true

    var body: some View {
        List {
            Section {
                Toggle("后台 App 刷新", isOn: $backgroundRefresh)
            } footer: {
                Text("允许虚拟机内的应用在后台刷新内容。")
            }
        }
        .navigationTitle("后台 App 刷新")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 5d. 日期与时间

/// Shows the real current date and time from the system clock.
private struct DateTimeView: View {
    @AppStorage("vm.settings.autoDateTime") private var autoDateTime = true

    var body: some View {
        List {
            Section {
                Toggle("自动设置", isOn: $autoDateTime)
            }
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    LabeledRow(label: "日期", value: VMTime.dateString(for: context.date))
                    LabeledRow(label: "时间", value: VMTime.timeString(for: context.date))
                }
            } header: {
                Text("当前时间")
            } footer: {
                Text("显示的是本机真实当前时间。")
            }
        }
        .navigationTitle("日期与时间")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 5e. 键盘

private struct KeyboardView: View {
    @AppStorage("vm.settings.keyboard") private var keyboard = "简体拼音"

    private let keyboards = ["简体拼音", "英文", "手写"]

    var body: some View {
        List {
            Section("键盘") {
                ForEach(keyboards, id: \.self) { name in
                    Button {
                        keyboard = name
                    } label: {
                        HStack {
                            Text(name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if name == keyboard {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("键盘")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 5f. 语言与地区

/// Stores the choice only; the VM UI is not re-localized.
private struct LanguageView: View {
    @AppStorage("vm.settings.language") private var language = "简体中文"

    private let languages = ["简体中文", "繁體中文", "English"]

    var body: some View {
        List {
            Section {
                ForEach(languages, id: \.self) { name in
                    Button {
                        language = name
                    } label: {
                        HStack {
                            Text(name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if name == language {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            } header: {
                Text("语言")
            } footer: {
                Text("仅保存选择，不改变本界面语言。")
            }
        }
        .navigationTitle("语言与地区")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 6. 关于本机

/// Every row is a real value from the system (hardware identifier, iOS
/// version, vendor identifier) or this app's own version. The fake rows
/// (iPhone 16 Pro / iOS 26.2 / 256 GB / VM20261117XXXX) are gone.
private struct AboutSettingsView: View {
    @AppStorage("vm.settings.deviceName") private var deviceName = "虚拟机"

    var body: some View {
        List {
            Section {
                NavigationLink {
                    DeviceNameEditView()
                } label: {
                    LabeledRow(label: "名称", value: deviceName)
                }
                LabeledRow(label: "型号", value: VMDevice.machineIdentifier())
                LabeledRow(label: "系统版本", value: "iOS \(VMDevice.systemVersion)")
                LabeledRow(label: "设备标识", value: VMDevice.vendorIdentifier)
                LabeledRow(label: "虚拟机版本", value: VMDevice.appVersionString)
            } footer: {
                Text("型号、系统版本与设备标识均取自本机真实系统；虚拟机版本为本 App 自身版本。")
            }
            // 诚实边界（设计 §5.1/D4）：六条逐行在列，不合并、不藏、不加修饰。
            // 0.2.38：原九条里的三条证书说明已删（证书说明只在虚拟机用户页，
            // 设置页不再放任何证书说明文案）。
            Section("诚实边界") {
                Text("容器不隔离：客 App 能直接读宿主文件，隔离只是约定的目录分组。")
                Text("权限全局共享：相机、定位等权限属于宿主进程，一次授权全客共享。")
                Text("entitlement 只用宿主的：客 App 原有的推送、App Groups 等权限在重签后丢失。")
                Text("远程推送不工作：客 App 没有推送 entitlement，收不到推送。")
                Text("扩展不支持：Widget、Share 扩展等无处注册。")
                Text("不承诺所有 IPA 都能跑：加密包、32 位、非 arm64 等应用打不开或功能缺失。")
            }
        }
        .navigationTitle("关于本机")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

/// Rename the device (VM-local display name, persisted).
private struct DeviceNameEditView: View {
    @AppStorage("vm.settings.deviceName") private var deviceName = "虚拟机"
    @State private var draft = ""

    var body: some View {
        List {
            Section {
                TextField("设备名称", text: $draft)
            } footer: {
                Text("改名后关于本机页同步显示新名字。")
            }
            Section {
                Button("保存") {
                    let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        deviceName = name
                    }
                }
            }
        }
        .navigationTitle("名称")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = deviceName }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 7. 显示与亮度

private struct DisplaySettingsView: View {
    @AppStorage("vm.settings.brightness") private var brightness = 0.7
    @AppStorage("vm.appearanceDark") private var appearanceDark = true
    @AppStorage("vm.settings.trueTone") private var trueTone = true

    /// The foreground window scene's screen; never UIScreen.main (deprecated).
    private static func keyScreen() -> UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.screen
        ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen
    }

    /// Slider binding: persists the value and applies it to the real screen.
    /// (A custom Binding avoids onChange entirely — no captured mutable state,
    /// and no deprecated single-parameter onChange on the iOS 16 target.)
    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { brightness },
            set: { newValue in
                brightness = newValue
                Self.keyScreen()?.brightness = CGFloat(newValue)
            }
        )
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "sun.min.fill")
                        .foregroundStyle(.secondary)
                    Slider(value: brightnessBinding, in: 0.1...1.0)
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("亮度")
            }
            Section {
                Picker("外观", selection: $appearanceDark) {
                    Text("浅色").tag(false)
                    Text("深色").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("原彩显示", isOn: $trueTone)
            } header: {
                Text("外观")
            } footer: {
                // 0.2.1：原彩开关只保存设置，App 改不了本机原彩，旧版没写明。
                Text("原彩显示只保存开关，改不了本机原彩设置。")
            }
        }
        .navigationTitle("显示与亮度")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Read the real screen brightness; the slider then reflects it.
            if let screen = Self.keyScreen() {
                brightness = Double(screen.brightness)
            }
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 8. 墙纸

/// The options live in VMWallpapers (VMHelpers.swift), shared with the
/// home screen — picking one here changes the home screen immediately.
/// 0.2.37：自选图片（MJ 22:39）——从相册/文件挑一张用户自己的图作墙纸，
/// 存盘持久化、重启与回桌面都还在、各页通用；没选时用下面的渐变。
/// 同一时间只一种墙纸生效：点渐变即清掉自选图，“恢复默认”也是清掉自选图。
private struct WallpaperSettingsView: View {
    @AppStorage("vm.settings.wallpaper") private var selectedWallpaper = 0
    @AppStorage("vm.settings.wallpaper.customVersion") private var customVersion = 0
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var customImage: UIImage?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    if let customImage {
                        Image(uiImage: customImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: 56, height: 100)
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                    }
                    Text(customImage == nil ? "未选用自选图片" : "已选用自选图片")
                        .foregroundStyle(.primary)
                    Spacer()
                    if customImage != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    Label("从相册选择", systemImage: "photo.on.rectangle")
                }
                Button {
                    showFileImporter = true
                } label: {
                    Label("从文件选择", systemImage: "folder")
                }
                if customImage != nil {
                    Button("恢复默认墙纸", role: .destructive) {
                        VMCustomWallpaper.remove()
                        bumpCustomVersion()
                    }
                }
            } header: {
                Text("自选图片")
            } footer: {
                Text("只用你自己挑的图片，不内置任何图片；选完立即换到主屏幕，重启后保持。")
            }
            Section {
                ForEach(VMWallpapers.options.indices, id: \.self) { index in
                    Button {
                        // 点渐变即清掉自选图：同一时间只一种墙纸生效。
                        if VMCustomWallpaper.hasCustom {
                            VMCustomWallpaper.remove()
                            bumpCustomVersion()
                        }
                        selectedWallpaper = index
                    } label: {
                        HStack(spacing: 14) {
                            LinearGradient(
                                colors: VMWallpapers.options[index].colors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .frame(width: 56, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(VMWallpapers.options[index].name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if index == selectedWallpaper && customImage == nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            } header: {
                Text("选取墙纸")
            } footer: {
                Text("墙纸会同步换到主屏幕，重启后保持。")
            }
        }
        .navigationTitle("墙纸")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
        .onAppear { customImage = VMCustomWallpaper.loadImage() }
        .onChange(of: customVersion) { _ in
            customImage = VMCustomWallpaper.loadImage()
        }
        .onChange(of: photoPickerItem) { newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   VMCustomWallpaper.save(image) {
                    bumpCustomVersion()
                }
                photoPickerItem = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url),
               let image = UIImage(data: data),
               VMCustomWallpaper.save(image) {
                bumpCustomVersion()
            }
        }
    }

    private func bumpCustomVersion() {
        customVersion += 1
        customImage = VMCustomWallpaper.loadImage()
    }
}

// MARK: - 8b. 虚拟机用户（Apple ID 卡片）

/// 0.2.37：虚拟机用户页（MJ 22:40）——按 iOS 设置页 Apple ID 账号页的样子：
/// 大头像＋名字＋邮箱；以下全是证书里的真实值（Team ID/过期日/导入日期），
/// 证书里没有的不编、不显示那行。头像可自选（相册/文件），只用用户自己挑的
/// 真实图片，没选时默认头像，可恢复默认。
/// 0.2.38：证书的显示与导入只在这页（导入／删除从设置页证书区搬来，
/// 自测不搬；证书区不再放任何说明文案）。
private struct AccountSettingsView: View {
    @AppStorage("vm.settings.avatar.customVersion") private var avatarVersion = 0
    /// 0.2.38：证书版本号——本页导入／删除成功后 +1，设置页账号卡片监听到即重读。
    @AppStorage("vm.settings.certificate.customVersion") private var certVersion = 0
    @State private var certInfo: SBCertificate.SBCertificateInfo?
    @State private var avatarImage: UIImage?
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showingAlert = false

    private var displayName: String {
        certInfo?.accountName ?? certInfo?.accountEmail ?? "虚拟机用户"
    }

    private var secondaryLine: String {
        if certInfo?.accountName != nil {
            return certInfo?.accountEmail
                ?? (certInfo?.teamID.map { "Team ID \($0)" } ?? "已导入证书")
        }
        if certInfo?.accountEmail != nil {
            return certInfo?.teamID.map { "Team ID \($0)" } ?? "已导入证书"
        }
        return certInfo == nil ? "未登录" : "已导入证书"
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    if let avatarImage {
                        Image(uiImage: avatarImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .frame(width: 72, height: 72)
                            .foregroundStyle(.gray)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName)
                            .font(.title3)
                        Text(secondaryLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                PhotosPicker(selection: $photoPickerItem, matching: .images) {
                    Label("更换头像", systemImage: "photo")
                }
                Button {
                    showFileImporter = true
                } label: {
                    Label("从文件选择头像", systemImage: "folder")
                }
                if avatarImage != nil {
                    Button("恢复默认头像", role: .destructive) {
                        VMUserAvatar.remove()
                        bumpAvatarVersion()
                    }
                }
            } footer: {
                Text("头像只用你自己挑的图片，不内置任何图片；换完各处头像同步变，重启后保持。")
            }
            Section {
                if let info = certInfo {
                    if let email = info.accountEmail {
                        LabeledRow(label: "Apple ID", value: email)
                    }
                    if let name = info.accountName {
                        LabeledRow(label: "姓名", value: name)
                    }
                    if let teamID = info.teamID {
                        LabeledRow(label: "Team ID", value: teamID)
                    }
                    if let expiration = info.expirationDate {
                        LabeledRow(label: "过期日", value: Self.formattedDate(expiration))
                    }
                    if let imported = info.importedDate {
                        LabeledRow(label: "导入日期", value: Self.formattedDate(imported))
                    }
                }
                // 0.2.38：导入／删除从设置页证书区搬来——证书的显示与导入只在这页。
                Button("导入证书") {
                    Task {
                        guard let presenter = Self.topViewController() else { return }
                        do {
                            try await SBCertificate.importP12(presenter: presenter)
                            certInfo = await SBCertificate.certificateInfo()
                            certVersion += 1
                        } catch {
                            if case SBError.cancelled = error { return }
                            await MainActor.run {
                                alertTitle = "导入证书失败"
                                alertMessage = error.localizedDescription
                                showingAlert = true
                            }
                        }
                    }
                }
                if certInfo != nil {
                    Button("删除证书", role: .destructive) {
                        Task {
                            do {
                                try SBCertificate.deleteCertificate()
                                certInfo = await SBCertificate.certificateInfo()
                                certVersion += 1
                            } catch {
                                await MainActor.run {
                                    alertTitle = "删除证书失败"
                                    alertMessage = error.localizedDescription
                                    showingAlert = true
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("证书")
            }
        }
        .navigationTitle("虚拟机用户")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
        .alert(Text(alertTitle), isPresented: $showingAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .task {
            certInfo = await SBCertificate.certificateInfo()
            avatarImage = VMUserAvatar.loadImage()
        }
        .onChange(of: avatarVersion) { _ in
            avatarImage = VMUserAvatar.loadImage()
        }
        .onChange(of: photoPickerItem) { newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   VMUserAvatar.save(image) {
                    bumpAvatarVersion()
                }
                photoPickerItem = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url),
               let image = UIImage(data: data),
               VMUserAvatar.save(image) {
                bumpAvatarVersion()
            }
        }
    }

    private func bumpAvatarVersion() {
        avatarVersion += 1
        avatarImage = VMUserAvatar.loadImage()
    }

    /// 顶层 presenter（证书导入的文件选择器 / 密码框用），做法与
    /// SBAppCoordinator.topViewController 一致；0.2.38 从设置页证书区搬来。
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: { $0.isKeyWindow })
            ?? scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    private static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - 9. 声音与触感

/// Ringtones are picked from iOS built-in names and persisted. Tapping an
/// option plays one real system sound (AudioServices) as feedback — the
/// app cannot play the named ringtone file itself, and does not claim to.
/// The volume slider reads the real AVAudioSession output volume on
/// appear; dragging only saves the VM-local setting — an app cannot
/// change the system volume, and the slider does not pretend to.
private struct SoundsSettingsView: View {
    @AppStorage("vm.settings.volume") private var volume = 0.5
    @AppStorage("vm.settings.vibration") private var vibration = true
    @AppStorage("vm.settings.ringtone") private var ringtone = "倒影"
    @AppStorage("vm.settings.textTone") private var textTone = "三全音"

    var body: some View {
        List {
            Section {
                NavigationLink {
                    TonePickerView(kind: .ringtone)
                } label: {
                    LabeledRow(label: "电话铃声", value: ringtone)
                }
                NavigationLink {
                    TonePickerView(kind: .textTone)
                } label: {
                    LabeledRow(label: "短信铃声", value: textTone)
                }
            }
            Section {
                HStack {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)
                    Slider(value: $volume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("铃声和提醒音量")
            } footer: {
                Text("滑条显示的是本机真实输出音量；拖动后只保存虚拟机内的音量设置，改不了系统音量。")
            }
            Section {
                Toggle("振动", isOn: $vibration)
            }
        }
        .navigationTitle("声音与触感")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Read the real output volume; the slider then reflects it.
            volume = Double(AVAudioSession.sharedInstance().outputVolume)
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

/// Ringtone / text-tone picker. The four names in each list are real
/// iOS built-in tone names, used as the VM's ringtone setting.
private enum ToneKind {
    case ringtone
    case textTone
}

private struct TonePickerView: View {
    let kind: ToneKind
    @AppStorage("vm.settings.ringtone") private var ringtone = "倒影"
    @AppStorage("vm.settings.textTone") private var textTone = "三全音"

    private var options: [String] {
        switch kind {
        case .ringtone: return ["倒影", "开场", "灯塔", "马林巴琴"]
        case .textTone: return ["三全音", "提示音", "钟声", "水滴"]
        }
    }

    private var selection: Binding<String> {
        switch kind {
        case .ringtone: return $ringtone
        case .textTone: return $textTone
        }
    }

    private var title: String {
        switch kind {
        case .ringtone: return "电话铃声"
        case .textTone: return "短信铃声"
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(options, id: \.self) { name in
                    Button {
                        selection.wrappedValue = name
                        // One real system sound as tap feedback.
                        AudioServicesPlaySystemSound(1007)
                    } label: {
                        HStack {
                            Text(name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if name == selection.wrappedValue {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            } header: {
                Text(title)
            } footer: {
                Text("点选时会响一声系统提示音作为反馈。")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 10. 面容 ID 与密码

/// The passcode is a VM-local 4-digit lock code, persisted in
/// @AppStorage. It is a demo setting for the VM, not a security feature.
private struct FaceIDSettingsView: View {
    @AppStorage("vm.settings.faceID") private var faceID = false
    @AppStorage("vm.settings.passcode") private var passcode = ""
    @State private var showingClearConfirm = false

    var body: some View {
        List {
            Section {
                Toggle("面容 ID", isOn: $faceID)
            } footer: {
                // 0.2.1：旧文案“可用于解锁与 App Store 购买”是假的——
                // 虚拟机没有录入面容，也买不了东西。开着只表示：设了密码后，
                // 启动时可用本机面容 ID 解锁虚拟机。
                Text("开启后，设置密码时可用本机面容 ID 解锁虚拟机。")
            }
            Section {
                NavigationLink {
                    PasscodeView()
                } label: {
                    LabeledRow(
                        label: passcode.isEmpty ? "设置密码" : "更改密码",
                        value: passcode.isEmpty ? "未设置" : "已设置"
                    )
                }
            } footer: {
                Text(passcode.isEmpty ? "未设置虚拟机密码。" : "已设置虚拟机 4 位密码，每次启动虚拟机时需要输入。")
            }
            // 0.2.39：清除密码（之前只有设置/更改，没有任何清除入口，
            // vm.settings.passcode 一旦写入就清不掉，只能删 App）。
            // 清除即把 @AppStorage("vm.settings.passcode") 写回 ""，
            // 下次冷启动 SealboxApp 的锁门（passcode.isEmpty）即不锁；
            // 面容 ID 开关只在有密码时有意义，一并关掉。
            if !passcode.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showingClearConfirm = true
                    } label: {
                        Text("清除密码")
                    }
                } footer: {
                    Text("清除后下次启动虚拟机不再出现锁屏。")
                }
            }
        }
        .navigationTitle("面容 ID 与密码")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
        .alert("清除进入密码？", isPresented: $showingClearConfirm) {
            Button("清除密码", role: .destructive) {
                passcode = ""
                faceID = false
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("清除后下次启动虚拟机不再需要输入密码。")
        }
    }
}

/// Set / change the VM 4-digit passcode. Flow: verify the old code first
/// (only when one is set), then enter the new code twice.
private struct PasscodeView: View {
    @AppStorage("vm.settings.passcode") private var passcode = ""
    @State private var entry = ""
    @State private var pendingNew = ""
    @State private var phase = 0 // 0: old (or new if none set) · 1: confirm new
    @State private var error = ""
    @State private var done = false

    private var hasPasscode: Bool { !passcode.isEmpty }

    private var prompt: String {
        if done { return "密码已保存" }
        if phase == 0 {
            return hasPasscode ? "输入旧密码" : "输入新密码"
        }
        return "再次输入新密码"
    }

    private var dots: some View {
        HStack(spacing: 16) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(index < entry.count ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: 14, height: 14)
            }
        }
    }

    var body: some View {
        VStack(spacing: 28) {
            Text(prompt)
                .font(.title3)
                .padding(.top, 48)
            dots
            if !error.isEmpty {
                Text(error)
                    .foregroundStyle(.red)
            }
            keypad
            Spacer()
        }
        .navigationTitle(hasPasscode ? "更改密码" : "设置密码")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }

    private var keypad: some View {
        let keys: [[String]] = [
            ["1", "2", "3"],
            ["4", "5", "6"],
            ["7", "8", "9"],
            ["", "0", "⌫"],
        ]
        return VStack(spacing: 16) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 28) {
                    ForEach(row, id: \.self) { key in
                        if key.isEmpty {
                            Color.clear.frame(width: 64, height: 64)
                        } else if key == "⌫" {
                            Button {
                                if !entry.isEmpty { entry.removeLast() }
                            } label: {
                                Image(systemName: "delete.left.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.primary)
                                    .frame(width: 64, height: 64)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button { pressDigit(key) } label: {
                                Text(key)
                                    .font(.system(size: 28, weight: .light))
                                    .foregroundStyle(.primary)
                                    .frame(width: 64, height: 64)
                                    .background(Color(.secondarySystemFill), in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func pressDigit(_ digit: String) {
        guard !done, entry.count < 4 else { return }
        entry.append(digit)
        guard entry.count == 4 else { return }
        if phase == 0 {
            if hasPasscode {
                if entry == passcode {
                    error = ""
                    entry = ""
                    phase = 1
                } else {
                    error = "旧密码不对"
                    entry = ""
                }
            } else {
                pendingNew = entry
                error = ""
                entry = ""
                phase = 1
            }
        } else {
            if entry == pendingNew {
                passcode = entry
                entry = ""
                error = ""
                done = true
            } else {
                error = "两次输入不一致，请重新输入"
                entry = ""
                pendingNew = ""
                phase = 0
            }
        }
    }
}

// MARK: - 11. 电池

/// Real battery level and charging state from UIDevice. The fake
/// "最大容量 100%" row is gone — the VM has no real source for it.
private struct BatterySettingsView: View {
    @AppStorage("vm.settings.batteryPercent") private var showPercent = true
    @State private var level: Float = -1
    @State private var state: UIDevice.BatteryState = .unknown

    private func refresh() {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        level = device.batteryLevel
        state = device.batteryState
    }

    private var levelText: String {
        guard level >= 0 else { return "未知" }
        if showPercent {
            return "\(Int(level * 100))%"
        }
        return "已隐藏百分比"
    }

    private var stateText: String {
        switch state {
        case .charging: return "正在充电"
        case .full: return "已充满"
        case .unplugged: return "未在充电"
        case .unknown: return "未知"
        @unknown default: return "未知"
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("电量百分比", isOn: $showPercent)
            }
            Section {
                LabeledRow(label: "当前电量", value: levelText)
                LabeledRow(label: "充电状态", value: stateText)
            } footer: {
                Text("电量与充电状态取自本机真实电池。")
            }
        }
        .navigationTitle("电池")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 12. 隐私与安全性

/// Photo access is a three-way VM-local setting; the microphone is a real
/// persisted switch. No fake permission values.
private struct PrivacySettingsView: View {
    @AppStorage("vm.settings.location") private var location = true
    @AppStorage("vm.settings.tracking") private var tracking = false
    @AppStorage("vm.settings.photoAccess") private var photoAccess = "所有照片"
    @AppStorage("vm.settings.microphone") private var microphone = false

    var body: some View {
        List {
            Section {
                Toggle("定位服务", isOn: $location)
                Toggle("跟踪", isOn: $tracking)
                Picker("照片", selection: $photoAccess) {
                    Text("所有照片").tag("所有照片")
                    Text("选中的照片").tag("选中的照片")
                    Text("不允许").tag("不允许")
                }
                Toggle("麦克风", isOn: $microphone)
            } footer: {
                Text("照片与麦克风为虚拟机内的权限设置，重启后保持。")
            }
        }
        .navigationTitle("隐私与安全性")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - Small helper

/// A static label/value row (no navigation).
private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if !value.isEmpty {
                Text(value)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
