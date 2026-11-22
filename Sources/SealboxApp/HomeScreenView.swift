import SwiftUI

// Home screen (0.1.4): two paged pages.
// Page 1: the three built-in apps. Page 2: installed apps from the source.
// Paging is TabView + PageTabViewStyle (0.2.3): the manual HStack+offset
// +drag pager failed on device three times (0.2.0 gated switch, 0.2.1
// simultaneousGesture, 0.2.2 unchanged) — its gesture arbitration with
// the icon Buttons and page 2's ScrollView is framework-internal and
// not provable from code. TabView paging is UIKit-native (UIScrollView-
// backed): horizontal paging, button taps, and the vertical list
// disambiguate by direction, as in every paged iOS UI. No switch, no
// custom gesture, no manual offset — nothing for a child gesture to
// outrank, and swiping and the dots below share the one vm.homePage
// binding, so they can never disagree.
struct HomeScreenView: View {
    @EnvironmentObject private var vm: VMState
    @EnvironmentObject private var coordinator: SBAppCoordinator
    @ObservedObject private var store = SBStore.shared
    @AppStorage("vm.plugin.iconThemeDark") private var iconThemeDark = false
    @AppStorage("vm.settings.wallpaper") private var selectedWallpaper = 0
    /// 0.2.37：自选墙纸版本号（存/删时 +1；HomeScreen 与墙纸页都监听它）。
    @AppStorage("vm.settings.wallpaper.customVersion") private var customWallpaperVersion = 0
    /// 当前自选墙纸图（无则 nil，走渐变墙纸）；进桌面与版本号变时重读文件。
    @State private var customWallpaperImage: UIImage?
    @State private var pendingDelete: SBInstalledApp? = nil
    @State private var showDeleteConfirm = false

    /// 桌面第 2 页：单源头 SBStore，按 desktopIconOrder 的 recordID 顺序排；
    /// 顺序里没有的（迁移刚建的）按安装时间排在后面。
    private var orderedInstalledApps: [SBInstalledApp] {
        let order = store.desktopIconOrder
        let apps = store.installedApps
        return apps.sorted { a, b in
            let ia = order.firstIndex(of: a.recordID.uuidString) ?? Int.max
            let ib = order.firstIndex(of: b.recordID.uuidString) ?? Int.max
            if ia != ib {
                return ia < ib
            }
            return a.installedDate < b.installedDate
        }
    }

    /// The home-screen wallpaper is the option picked on the wallpaper
    /// page (vm.settings.wallpaper); it survives restarts via @AppStorage.
    private var wallpaperColors: [Color] { VMWallpapers.colors(for: selectedWallpaper) }

    /// 0.2.38：墙纸背景层——只做背景，不参与布局。`.background` 的内容
    /// 按宿主（VStack）尺寸铺，绝不反向决定宿主大小；自选图用
    /// scaledToFill 铺满并裁掉溢出，黑遮罩与渐变色块同理。换任何比例
    /// 的图，图标网格／文字／Dock 的位置都与无墙纸时完全一致。
    private var wallpaperBackground: some View {
        ZStack {
            // Wallpaper：有自选图时用用户自己的图（各页通用），没有时用选中的渐变。
            if let customWallpaperImage {
                Image(uiImage: customWallpaperImage)
                    .resizable()
                    .scaledToFill()
                // 轻遮罩：白字标签/白圆点在亮图上仍可读，图本身只暗一点。
                Color.black.opacity(0.12)
            } else {
                // Wallpaper: the selected option's gradient with soft color blobs.
                LinearGradient(
                    colors: wallpaperColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
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
            }
        }
        .ignoresSafeArea()
        .clipped()
    }

    var body: some View {
        // 0.2.38：墙纸只做背景层，不参与布局尺寸——VStack 的 .background
        // 内容按 VStack 自身尺寸铺，不反向决定 VStack 的大小；换任何
        // 比例的自选图，图标网格／文字／Dock 的位置都与无墙纸时一致。
        // （0.2.37 把图放在 ZStack 子层：可缩放图片的理想尺寸会把
        // ZStack 撑大，VStack 在撑大的 ZStack 里居中，图标位置跟着移。）
        VStack(spacing: 0) {
            // Clear the real system status bar / Dynamic Island.
            Spacer()
                .frame(height: 54)

            // Two pages, standard paging (0.2.3): TabView +
            // PageTabViewStyle. The manual HStack+offset+drag pager
            // failed on device twice (0.2.1 simultaneousGesture,
            // 0.2.2 unchanged) — its gesture arbitration with the
            // icon Buttons and page 2's vertical ScrollView is
            // framework-internal and not provable from code.
            // TabView paging is UIKit-native (UIScrollView-backed):
            // horizontal paging, button taps, and the vertical list
            // disambiguate by direction, as in every paged iOS UI.
            // Selection is the single vm.homePage binding, so swiping
            // and the dots below always agree; no switch, no custom
            // gesture, nothing for a child gesture to outrank.
            GeometryReader { geo in
                TabView(selection: $vm.homePage) {
                    builtInPage(width: geo.size.width)
                        .tag(0)
                    installedPage(width: geo.size.width)
                        .tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            // Page dots: iOS standard position, just above the Dock.
            // Always tappable, same as swiping.
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
        .background {
            wallpaperBackground
        }
        .onAppear {
            // 0.2.37：进桌面（与从客回桌面）时重读自选墙纸——文件在即显示，
            // 文件没了（删了/没选过）即回渐变。
            customWallpaperImage = VMCustomWallpaper.loadImage()
        }
        .onChange(of: customWallpaperVersion) { _ in
            customWallpaperImage = VMCustomWallpaper.loadImage()
        }
        .overlay {
            // 0.2.44（F6）：点按即显示加载态——coordinator.launchingBundleID
            // 非空时叠 spinner＋“正在启动…”，点图标后第一帧即有反馈；
            // 成功／失败回调里清掉（恢复路是同步的，不设它）。
            if let launchingBundleID = coordinator.launchingBundleID {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.4)
                    Text("正在启动\(store.installedApps.first { $0.bundleID == launchingBundleID }.map { SBStore.shared.displayName(for: $0) } ?? "")…")
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
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
            if orderedInstalledApps.isEmpty {
                Spacer()
                Text("还没有安装的应用\n去软件源获取")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.85))
                Button("导入 IPA") {
                    coordinator.importIPA()
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .padding(.top, 16)
                Spacer()
            } else {
                HStack {
                    // 0.2.44（问题 3）：桌面可见的切换器入口——与客内横杠长按
                    // 同一个通知（SBGuestSwitcherRequested），VMRootView 接到
                    // 即弹切换器；无后台客时切换器只显示“没有正在运行的应用”。
                    Button("切换器") {
                        // ObjC 常量 SBGuestSwitcherRequestedNotification 在 Swift
                        // 里被导入器重命名为 NSNotification.Name.SBGuestSwitcherRequested
                        //（去 Notification 后缀），直接用该名。
                        NotificationCenter.default.post(
                            name: .SBGuestSwitcherRequested, object: nil)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.small)
                    Spacer()
                    Button("导入 IPA") {
                        coordinator.importIPA()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.small)
                }
                .padding(.horizontal, 26)
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
                        ForEach(orderedInstalledApps) { app in
                            Button { handleIconTap(app) } label: {
                                VStack(spacing: 6) {
                                    InstalledAppIconView(app: app, size: 64)
                                    Text(SBStore.shared.displayName(for: app))
                                        .font(.system(size: 12))
                                        .foregroundColor(.white)
                                        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                                        .lineLimit(1)
                                }
                                // 需重新导入的记录灰色显示。
                                .opacity(app.needsReimport ? 0.45 : 1.0)
                            }
                            .buttonStyle(TapZoomButtonStyle())
                            .contextMenu {
                                Button("详情") {
                                    vm.openApp = .installed(app.recordID.uuidString)
                                }
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
            "删除“\(pendingDelete.map { SBStore.shared.displayName(for: $0) } ?? "")”？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let app = pendingDelete {
                    coordinator.deleteApp(app)
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("将删除应用本体、数据容器、钥匙串记录与桌面记录，原始 IPA 文件保留在 Documents/IPAs。")
        }
    }

    /// 点图标：需重新导入的记录只进详情页（重新导入 / 删除，不启动）；
    /// 其余走启动链（JIT 预检与证书门在 coordinator.launchApp 里）。
    private func handleIconTap(_ app: SBInstalledApp) {
        if app.needsReimport {
            vm.openApp = .installed(app.recordID.uuidString)
        } else {
            coordinator.launchApp(app)
        }
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

/// 点按缩放：按下时图标从自身中心缩小，松开复原，点按必有可见反馈。
/// 用 ButtonStyle 的 isPressed 驱动，不抢 Dock/翻页手势；图标位置恒有，
/// 缩放锚点就是图标中心（无图标位置的兜底分支见 0.0.9：从屏幕中心起——
/// 桌面网格里每次点按都有图标，走不到兜底）。
struct TapZoomButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.82 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
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
