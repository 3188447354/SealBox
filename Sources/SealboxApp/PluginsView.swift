import SwiftUI

// Plugins (0.1.4): three toggles, each backed by a fixed @AppStorage key
// so the same value is read by the home screen and the root view.
// The list and the detail pages share the same bindings.
struct PluginsView: View {
    @AppStorage("vm.plugin.iconThemeDark") private var iconThemeDark = false
    @AppStorage("vm.plugin.statusBarFancy") private var statusBarFancy = false
    @AppStorage("vm.plugin.customGestures") private var customGestures = false
    @State private var searchText = ""

    private var filteredPlugins: [PluginKind] {
        guard !searchText.isEmpty else { return PluginKind.allCases }
        return PluginKind.allCases.filter {
            $0.name.contains(searchText) || $0.intro.contains(searchText)
        }
    }

    private func binding(for plugin: PluginKind) -> Binding<Bool> {
        switch plugin {
        case .iconTheme: return $iconThemeDark
        case .statusBar: return $statusBarFancy
        case .customGestures: return $customGestures
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredPlugins) { plugin in
                    NavigationLink {
                        PluginDetailView(plugin: plugin, isOn: binding(for: plugin))
                    } label: {
                        PluginRow(plugin: plugin, isOn: binding(for: plugin))
                    }
                }
            }
            .navigationTitle("插件")
            .searchable(text: $searchText, prompt: "搜索插件")
            // Keep the bottom 28pt clear: the root view's swipe-up-to-home
            // zone lives there, so no tappable row may sit in it.
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 28)
            }
        }
    }
}

private enum PluginKind: String, CaseIterable, Identifiable {
    case iconTheme
    case statusBar
    case customGestures

    var id: String { rawValue }

    var name: String {
        switch self {
        case .iconTheme: return "图标主题"
        case .statusBar: return "状态栏美化"
        case .customGestures: return "自定义手势"
        }
    }

    var intro: String {
        switch self {
        case .iconTheme: return "主屏幕图标换成更深的配色"
        case .statusBar: return "应用内改画状态栏，显示秒数"
        case .customGestures: return "主屏幕支持左右滑动切页"
        }
    }

    var symbol: String {
        switch self {
        case .iconTheme: return "paintpalette.fill"
        case .statusBar: return "clock.fill"
        case .customGestures: return "hand.draw.fill"
        }
    }

    var tint: Color {
        switch self {
        case .iconTheme: return .purple
        case .statusBar: return .blue
        case .customGestures: return .green
        }
    }
}

private struct PluginRow: View {
    let plugin: PluginKind
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(plugin.tint)
                    .frame(width: 40, height: 40)
                Image(systemName: plugin.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.system(size: 16))
                Text(plugin.intro)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
    }
}

private struct PluginDetailView: View {
    let plugin: PluginKind
    @Binding var isOn: Bool

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(plugin.tint)
                            .frame(width: 64, height: 64)
                        Image(systemName: plugin.symbol)
                            .font(.system(size: 30, weight: .medium))
                            .foregroundColor(.white)
                    }
                    Text(plugin.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(plugin.intro)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                Toggle("启用", isOn: $isOn)
            }

            Section {
                HStack {
                    Text("版本")
                    Spacer()
                    Text("1.0")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(plugin.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 28)
        }
    }
}

// MARK: - Fancy status bar

/// Drawn-in status bar shown by the root view when the status-bar plugin
/// is on (the system status bar is hidden at the same time).
/// Top 54pt only: time with seconds on the left, signal / Wi-Fi / battery
/// on the right. Display-only — it never intercepts touches and never
/// reaches the Dock at the bottom.
struct FancyStatusBar: View {
    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    Text(timeString(for: context.date))
                        .monospacedDigit()
                    Spacer()
                    Image(systemName: "cellularbars")
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(height: 54)
                .padding(.horizontal, 20)
            }
            Spacer()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// 24-hour HH:MM:SS, built from date components so there is no shared
    /// DateFormatter (Swift 6 concurrency-safe).
    private func timeString(for date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
    }
}
