import SwiftUI

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
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var vm: VMState
    @State private var searchText = ""
    @AppStorage("vm.settings.wifiNetwork") private var wifiNetwork = "SealBox-5G"

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    private var searchResults: [SettingsDestination] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return SettingsDestination.allCases.filter { $0.rawValue.localizedCaseInsensitiveContains(query) }
    }

    /// Whether "软件源" / "插件" match the current search text.
    private func appRowMatches(_ name: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return !query.isEmpty && name.localizedCaseInsensitiveContains(query)
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
        }
    }

    // MARK: - Main lists

    private var groupedList: some View {
        List {
            // Account card
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .frame(width: 56, height: 56)
                        .foregroundStyle(.gray)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("虚拟机用户")
                            .font(.title3)
                        Text("Apple 账号")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
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

            // Group 3: other built-in apps (switch apps, not sub-pages)
            Section {
                Button { vm.openApp = .source } label: {
                    AppSwitchRow(icon: "arrow.down.circle.fill", color: .blue, title: "软件源")
                }
                Button { vm.openApp = .plugins } label: {
                    AppSwitchRow(icon: "puzzlepiece.extension.fill", color: .purple, title: "插件")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }

    /// Flat results while searching; tapping one opens its sub-page.
    private var searchList: some View {
        List {
            ForEach(searchResults, id: \.self) { destination in
                NavigationLink(value: destination) {
                    SettingsRow(destination: destination, detail: destination == .wifi ? wifiNetwork : nil)
                }
            }
            if appRowMatches("软件源") {
                Button { vm.openApp = .source } label: {
                    AppSwitchRow(icon: "arrow.down.circle.fill", color: .blue, title: "软件源")
                }
            }
            if appRowMatches("插件") {
                Button { vm.openApp = .plugins } label: {
                    AppSwitchRow(icon: "puzzlepiece.extension.fill", color: .purple, title: "插件")
                }
            }
            if searchResults.isEmpty && !appRowMatches("软件源") && !appRowMatches("插件") {
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

/// Row for the third group: switches to another built-in app.
private struct AppSwitchRow: View {
    let icon: String
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: icon, color: color)
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
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

private struct BluetoothSettingsView: View {
    @AppStorage("vm.settings.bluetooth") private var bluetoothOn = true

    private let devices: [(name: String, connected: Bool)] = [
        ("AirPods Pro", true),
        ("Apple Watch", true),
        ("Magic Keyboard", false),
        ("车载蓝牙", false),
    ]

    var body: some View {
        List {
            Section {
                Toggle("蓝牙", isOn: $bluetoothOn)
            }
            if bluetoothOn {
                Section("我的设备") {
                    ForEach(devices, id: \.name) { device in
                        HStack {
                            Text(device.name)
                            Spacer()
                            Text(device.connected ? "已连接" : "未连接")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("蓝牙")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 3. 蜂窝网络

private struct CellularSettingsView: View {
    @AppStorage("vm.settings.cellular") private var cellularOn = true

    var body: some View {
        List {
            Section {
                Toggle("蜂窝数据", isOn: $cellularOn)
            }
            if cellularOn {
                Section("流量统计") {
                    LabeledRow(label: "本月已用", value: "12.4 GB")
                    LabeledRow(label: "上月用量", value: "9.8 GB")
                    LabeledRow(label: "本月剩余", value: "7.6 GB")
                    LabeledRow(label: "统计周期", value: "每月 1 日重置")
                }
            }
        }
        .navigationTitle("蜂窝网络")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 4. 个人热点

private struct HotspotSettingsView: View {
    @AppStorage("vm.settings.hotspot") private var hotspotOn = false

    var body: some View {
        List {
            Section {
                Toggle("允许其他人加入", isOn: $hotspotOn)
            }
            Section {
                LabeledRow(label: "无线局域网密码", value: "SealBox1234")
                LabeledRow(label: "最多连接数", value: "5 台设备")
            } footer: {
                Text("开启个人热点后，其他设备可通过无线局域网加入并共享蜂窝数据。")
            }
        }
        .navigationTitle("个人热点")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 5. 通用

private struct GeneralSettingsView: View {
    var body: some View {
        List {
            Section {
                NavigationLink("关于本机", value: SettingsDestination.about)
                LabeledRow(label: "软件更新", value: "iOS 26.2")
                LabeledRow(label: "储存空间", value: "已用 58 GB，共 256 GB")
                LabeledRow(label: "后台 App 刷新", value: "开")
                LabeledRow(label: "日期与时间", value: "自动设置")
                LabeledRow(label: "键盘", value: "简体拼音")
                LabeledRow(label: "语言与地区", value: "简体中文")
            }
        }
        .navigationTitle("通用")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 6. 关于本机

private struct AboutSettingsView: View {
    var body: some View {
        List {
            Section {
                LabeledRow(label: "名称", value: "虚拟机")
                LabeledRow(label: "型号", value: "iPhone 16 Pro")
                LabeledRow(label: "版本", value: "iOS 26.2（虚拟机）")
                LabeledRow(label: "容量", value: "256 GB（可用 198 GB）")
                LabeledRow(label: "序列号", value: "VM20261117XXXX")
            }
        }
        .navigationTitle("关于本机")
        .navigationBarTitleDisplayMode(.inline)
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

private struct WallpaperSettingsView: View {
    @AppStorage("vm.settings.wallpaper") private var selectedWallpaper = 0

    private let wallpapers: [(name: String, colors: [Color])] = [
        ("蓝紫粉渐变", [.blue, .purple, .pink]),
        ("深海蓝", [.blue, .teal, .black]),
        ("落日橙", [.orange, .pink, .purple]),
        ("森林绿", [.green, .teal, .mint]),
    ]

    var body: some View {
        List {
            Section("选取墙纸") {
                ForEach(wallpapers.indices, id: \.self) { index in
                    Button {
                        selectedWallpaper = index
                    } label: {
                        HStack(spacing: 14) {
                            LinearGradient(
                                colors: wallpapers[index].colors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .frame(width: 56, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            Text(wallpapers[index].name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if index == selectedWallpaper {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("墙纸")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 9. 声音与触感

private struct SoundsSettingsView: View {
    @AppStorage("vm.settings.volume") private var volume = 0.5
    @AppStorage("vm.settings.vibration") private var vibration = true

    var body: some View {
        List {
            Section {
                LabeledRow(label: "电话铃声", value: "倒影")
                LabeledRow(label: "短信铃声", value: "提示音")
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
            }
            Section {
                Toggle("振动", isOn: $vibration)
            }
        }
        .navigationTitle("声音与触感")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 10. 面容 ID 与密码

private struct FaceIDSettingsView: View {
    @AppStorage("vm.settings.faceID") private var faceID = false

    var body: some View {
        List {
            Section {
                Toggle("面容 ID", isOn: $faceID)
            } footer: {
                Text(faceID ? "面容 ID 已设置，可用于解锁与 App Store 购买。" : "未设置面容 ID。开启后可用于解锁与 App Store 购买。")
            }
            Section {
                LabeledRow(label: "密码", value: "已设置")
                LabeledRow(label: "更改密码", value: "")
            }
        }
        .navigationTitle("面容 ID 与密码")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 11. 电池

private struct BatterySettingsView: View {
    @AppStorage("vm.settings.batteryPercent") private var showPercent = true

    var body: some View {
        List {
            Section {
                Toggle("电量百分比", isOn: $showPercent)
            }
            Section {
                LabeledRow(label: "当前电量", value: showPercent ? "82%" : "82")
                LabeledRow(label: "电池健康", value: "最大容量 100%")
                LabeledRow(label: "充电状态", value: "未在充电")
            }
        }
        .navigationTitle("电池")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - 12. 隐私与安全性

private struct PrivacySettingsView: View {
    @AppStorage("vm.settings.location") private var location = true
    @AppStorage("vm.settings.tracking") private var tracking = false

    var body: some View {
        List {
            Section {
                Toggle("定位服务", isOn: $location)
                Toggle("跟踪", isOn: $tracking)
                LabeledRow(label: "照片", value: "所有照片")
                LabeledRow(label: "麦克风", value: "开启")
            } footer: {
                Text("定位服务与跟踪由上方开关控制；照片与麦克风权限按 App 逐项设置。")
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
