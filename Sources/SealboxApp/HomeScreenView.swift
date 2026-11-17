import SwiftUI

// Home screen (0.1.4): two manually paged pages.
// Page 1: the three built-in apps. Page 2: installed apps from the source.
// Paging is a plain HStack with an offset — no TabView — so the swipe
// gesture can be gated on the custom-gestures plugin switch.
struct HomeScreenView: View {
    @EnvironmentObject private var vm: VMState
    @AppStorage("vm.plugin.iconThemeDark") private var iconThemeDark = false
    @AppStorage("vm.plugin.customGestures") private var customGestures = false
    @AppStorage("vm.settings.wallpaper") private var selectedWallpaper = 0
    @State private var pendingDelete: InstalledApp? = nil
    @State private var showDeleteConfirm = false

    /// The home-screen wallpaper is the option picked on the wallpaper
    /// page (vm.settings.wallpaper); it survives restarts via @AppStorage.
    private var wallpaperColors: [Color] { VMWallpapers.colors(for: selectedWallpaper) }

    var body: some View {
        ZStack {
            // Wallpaper: the selected option's gradient with soft color blobs.
            LinearGradient(
                colors: wallpaperColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            Circle()
                .fill((wallpaperColors.first ?? .blue).opacity(0.55))
                .frame(width: 340, height: 340)
                .blur(radius: 60)
                .offset(x: -110, y: -260)
            Circle()
                .fill((wallpaperColors.last ?? .pink).opacity(0.45))
                .frame(width: 300, height: 300)
                .blur(radius: 70)
                .offset(x: 130, y: 140)

            VStack(spacing: 0) {
                // Clear the real system status bar / Dynamic Island.
                Spacer()
                    .frame(height: 54)

                // Two pages, side by side, slid by offset.
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        builtInPage(width: geo.size.width)
                        installedPage(width: geo.size.width)
                    }
                    .offset(x: -CGFloat(vm.homePage) * geo.size.width)
                    .animation(.easeInOut(duration: 0.28), value: vm.homePage)
                    .gesture(pageDragGesture)
                }

                // Page dots: iOS standard position, just above the Dock.
                // Always tappable, even when the swipe gesture is switched off.
                HStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { page in
                        Button {
                            vm.homePage = page
                        } label: {
                            Circle()
                                .fill(page == vm.homePage ? Color.white : Color.white.opacity(0.4))
                                .frame(width: 7, height: 7)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 12)

                // Dock: four working system apps.
                HStack(spacing: 0) {
                    Button { vm.openApp = .phone } label: {
                        DockIcon(symbol: "phone.fill", gradient: dockPhoneGradient)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { vm.openApp = .safari } label: {
                        DockIcon(symbol: "safari",
                                 gradient: dockSafariGradient,
                                 symbolColor: dockSafariSymbolColor)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { vm.openApp = .messages } label: {
                        DockIcon(symbol: "message.fill", gradient: dockMessageGradient)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { vm.openApp = .music } label: {
                        DockIcon(symbol: "music.note", gradient: dockMusicGradient)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Page 1: built-in apps

    private func builtInPage(width: CGFloat) -> some View {
        VStack {
            HStack(alignment: .top, spacing: 26) {
                Button { vm.openApp = .settings } label: {
                    HomeAppIcon(
                        label: "设置",
                        symbol: "gearshape.fill",
                        gradient: settingsGradient
                    )
                }
                .buttonStyle(.plain)
                Button { vm.openApp = .source } label: {
                    HomeAppIcon(
                        label: "软件源",
                        symbol: "arrow.down.to.line",
                        gradient: sourceGradient
                    )
                }
                .buttonStyle(.plain)
                Button { vm.openApp = .plugins } label: {
                    HomeAppIcon(
                        label: "插件",
                        symbol: "puzzlepiece.extension.fill",
                        gradient: pluginsGradient
                    )
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 26)
            Spacer()
        }
        .frame(width: width)
    }

    // MARK: - Page 2: installed apps

    private func installedPage(width: CGFloat) -> some View {
        VStack {
            if vm.installed.isEmpty {
                Spacer()
                Text("还没有安装的应用\n去软件源获取")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                        ],
                        spacing: 24
                    ) {
                        ForEach(vm.installed) { app in
                            Button { vm.openApp = .installed(app.name) } label: {
                                VStack(spacing: 6) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 16)
                                            .fill(colorForApp(named: app.name))
                                            .frame(width: 64, height: 64)
                                        Text(String(app.name.prefix(1)))
                                            .font(.system(size: 28, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                                    Text(app.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(.white)
                                        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("删除", role: .destructive) {
                                    pendingDelete = app
                                    showDeleteConfirm = true
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 8)
                }
            }
        }
        .frame(width: width)
        .confirmationDialog(
            "删除“\(pendingDelete?.name ?? "")”？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let app = pendingDelete {
                    vm.removeInstalled(app.name)
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("将删除已下载的 IPA 文件与记录。")
        }
    }

    // MARK: - Paging gesture

    /// Always attached; the onEnded handler checks the switch first,
    /// so turning the plugin off leaves the gesture inert.
    private var pageDragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard customGestures else { return }
                if value.translation.width < -50 {
                    vm.homePage = min(1, vm.homePage + 1)
                } else if value.translation.width > 50 {
                    vm.homePage = max(0, vm.homePage - 1)
                }
            }
    }

    // MARK: - Installed-app colors

    /// Fixed palette; the color is picked by a stable hash of the name
    /// (sum of Unicode scalars — Swift's hashValue is randomised per run).
    private func colorForApp(named name: String) -> Color {
        let palette: [Color] = [
            .blue, .green, .orange, .purple, .pink, .teal, .red, .indigo,
        ]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }

    // MARK: - Icon theme (light vs. dark)

    private var settingsGradient: [Color] {
        iconThemeDark
            ? [Color(red: 0.28, green: 0.28, blue: 0.30), Color(red: 0.16, green: 0.16, blue: 0.18)]
            : [Color(red: 0.56, green: 0.56, blue: 0.58), Color(red: 0.39, green: 0.39, blue: 0.40)]
    }

    private var sourceGradient: [Color] {
        iconThemeDark
            ? [Color(red: 0.02, green: 0.28, blue: 0.60), Color(red: 0.05, green: 0.38, blue: 0.70)]
            : [Color(red: 0.04, green: 0.52, blue: 1.0), Color(red: 0.19, green: 0.69, blue: 1.0)]
    }

    private var pluginsGradient: [Color] {
        iconThemeDark
            ? [Color(red: 0.38, green: 0.16, blue: 0.50), Color(red: 0.26, green: 0.08, blue: 0.52)]
            : [Color(red: 0.69, green: 0.32, blue: 0.87), Color(red: 0.49, green: 0.17, blue: 0.91)]
    }

    private var dockPhoneGradient: [Color] {
        iconThemeDark
            ? [Color(red: 0.08, green: 0.42, blue: 0.18), Color(red: 0.08, green: 0.42, blue: 0.18)]
            : [Color(red: 0.20, green: 0.78, blue: 0.35), Color(red: 0.20, green: 0.78, blue: 0.35)]
    }

    private var dockSafariGradient: [Color] {
        iconThemeDark
            ? [Color(red: 0.16, green: 0.18, blue: 0.22), Color(red: 0.16, green: 0.18, blue: 0.22)]
            : [Color.white, Color.white]
    }

    private var dockSafariSymbolColor: Color {
        iconThemeDark
            ? Color(red: 0.45, green: 0.75, blue: 1.0)
            : Color(red: 0.04, green: 0.52, blue: 1.0)
    }

    private var dockMessageGradient: [Color] {
        iconThemeDark
            ? [Color(red: 0.08, green: 0.45, blue: 0.18), Color(red: 0.08, green: 0.45, blue: 0.18)]
            : [Color(red: 0.19, green: 0.82, blue: 0.35), Color(red: 0.19, green: 0.82, blue: 0.35)]
    }

    private var dockMusicGradient: [Color] {
        iconThemeDark
            ? [Color(red: 0.55, green: 0.10, blue: 0.22), Color(red: 0.50, green: 0.08, blue: 0.16)]
            : [Color(red: 0.99, green: 0.23, blue: 0.42), Color(red: 0.98, green: 0.18, blue: 0.28)]
    }
}

private struct HomeAppIcon: View {
    let label: String
    let symbol: String
    let gradient: [Color]

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom))
                    .frame(width: 64, height: 64)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(.white)
            }
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
        }
    }
}

private struct DockIcon: View {
    let symbol: String
    let gradient: [Color]
    var symbolColor: Color = .white

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15)
                .fill(LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom))
                .frame(width: 60, height: 60)
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(symbolColor)
        }
    }
}
