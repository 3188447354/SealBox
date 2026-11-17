// 桌面主视图：壁纸、分页网格、Dock、搜索、控制中心、编辑态与证书门。
import SwiftUI

/// 外部传入的安装进度：进度由安装方更新，本视图只展示 pill。
final class SBInstallProgress: ObservableObject {
    @Published var progress: Double = 0
    @Published var label: String = ""
    @Published var isInstalling: Bool = false
}

/// 桌面主视图。
/// - 点图标：先过证书门（SBCertificate.hasCertificate 为 false 时不做缩放动画，
///   直接调 onNeedCertificate 弹缺证书引导）；通过后做 SBLaunchZoom 再调 onLaunchApp。
/// - 删除：确认 sheet 后调 onDeleteApp，真删在调用方；删失败由调用方回传 deleteError，本页只弹错。
/// - 拖动：搜索时禁用；其余时序见 SBDesktopDragState。
struct SBDesktopView: View {
    /// 订阅 Store 的已装列表：安装/删除后 @Published 变化即刷新桌面。
    @EnvironmentObject private var store: SBStore

    var installProgress: SBInstallProgress = SBInstallProgress()
    var jitEnabled: Bool = false
    var onLaunchApp: ((SBInstalledApp) -> Void)?
    var onDeleteApp: ((SBInstalledApp) -> Void)?
    var onNeedCertificate: (() -> Void)?
    /// 导入入口（空态按钮与编辑态“+”格调用），真导入在调用方。
    var onImport: (() -> Void)?
    /// 打开设置页（控制中心里的“设置”行调用）。
    var onOpenSettings: (() -> Void)?
    /// 调用方回传的删除失败错误，有值时只弹错、桌面不动。
    var deleteError: Error?

    @StateObject private var dragState = SBDesktopDragState()
    @State private var currentPage: Int = 0
    @State private var isEditing: Bool = false
    @State private var isSearching: Bool = false
    @State private var searchQuery: String = ""
    @State private var showingControlCenter: Bool = false
    @State private var toastMessage: String?
    @State private var zoomingApp: SBInstalledApp?
    @State private var zoomAnchor: CGPoint?
    @State private var appPendingDelete: SBInstalledApp?
    @State private var detailApp: SBInstalledApp?
    @State private var showingDetail: Bool = false
    @State private var showingDeleteError: Bool = false

    private let appsPerPage = 24

    var body: some View {
        ZStack {
            wallpaperView

            VStack(spacing: 0) {
                // 顶部安装 pill：安装中才出现。
                if installProgress.isInstalling {
                    HStack(spacing: 8) {
                        ProgressView(value: installProgress.progress)
                            .progressViewStyle(.linear)
                            .frame(width: 120)
                        Text(installProgress.label)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                        Text("\(Int(installProgress.progress * 100))%")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
                    .padding(.top, 12)
                }

                if gridApps.isEmpty, dockApps.isEmpty {
                    // D4 空态：只有壁纸 + 一行极淡提示 + 一个导入按钮（首装入口）。
                    Spacer()
                    Text("还没有安装应用")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.7))
                        .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                    Button(action: { onImport?() }) {
                        Label("导入 IPA", systemImage: "square.and.arrow.down")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Capsule())
                    }
                    .padding(.top, 16)
                    Spacer()
                } else if isSearching {
                    SBDesktopSearchResultsView(
                        results: SBDesktopSearch.filter(apps: orderedApps, query: searchQuery),
                        query: searchQuery,
                        onSelect: { app in
                            isSearching = false
                            searchQuery = ""
                            handleTap(app: app, anchor: nil)
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    Spacer()
                } else {
                    // 分页网格：每页 24，4 列 × 6 行。
                    TabView(selection: $currentPage) {
                        ForEach(pages.indices, id: \.self) { pageIndex in
                            gridPage(pages[pageIndex], page: pageIndex)
                                .tag(pageIndex)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .onChange(of: currentPage) { _ in
                        // 翻页即退出拖动占位，避免占位格跨页残留。
                        if dragState.isDragging { dragState.cancel() }
                    }

                    // 自画页点：可点；只有一页时隐藏。
                    if pages.count > 1 {
                        HStack(spacing: 8) {
                            ForEach(pages.indices, id: \.self) { index in
                                Button(action: { currentPage = index }) {
                                    Circle()
                                        .fill(index == currentPage ? Color.white : Color.white.opacity(0.5))
                                        .frame(width: 8, height: 8)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                Spacer(minLength: 0)
            }
            // 左上角下滑是通知中心入口：v1 不做，只回弹 + toast。
            .overlay(alignment: .topLeading) {
                Color.clear
                    .frame(width: 140, height: 44)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                if value.translation.height > 60 {
                                    showNotificationCenterUnavailable()
                                }
                            }
                    )
            }
            // 右上角下滑唤出控制中心的手势区（44pt 高、右侧 140pt 宽）。
            .overlay(alignment: .topTrailing) {
                Color.clear
                    .frame(width: 140, height: 44)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                if value.translation.height > 60 {
                                    showingControlCenter = true
                                }
                            }
                    )
            }
            // 中部下拉唤出搜索：网格区向下拖超过 80pt。
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        if value.translation.height > 80, !isEditing, !dragState.isDragging {
                            isSearching = true
                        }
                    }
            )

            // 悬浮搜索框。
            if isSearching {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        TextField("搜索应用名字或 Bundle ID", text: $searchQuery)
                            .textFieldStyle(.plain)
                        if !searchQuery.isEmpty {
                            Button(action: { searchQuery = "" }) {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                        }
                        Button("取消") {
                            isSearching = false
                            searchQuery = ""
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 4)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    Spacer()
                }
            }

            // 控制中心。
            if showingControlCenter {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { showingControlCenter = false }
                VStack {
                    SBControlCenter(jitEnabled: jitEnabled, onClose: { showingControlCenter = false }, onOpenSettings: { onOpenSettings?() })
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    Spacer()
                }
            }

            // 拖动 ghost：放大 1.15 + 阴影（Cell 侧实现）。
            if dragState.isDragging, let bundleID = dragState.draggedBundleID,
               let app = SBStore.shared.app(with: bundleID) {
                SBDesktopCell(app: app, iconSize: 58, isGhost: true)
                    .position(dragState.dragLocation)
            }

            // 点图标开场缩放。
            if let zoomApp = zoomingApp {
                SBLaunchZoom(anchor: zoomAnchor) {
                    zoomingApp = nil
                    onLaunchApp?(zoomApp)
                }
            }

            // Toast（通知中心 v1 未提供等）。
            if let toast = toastMessage {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.75))
                        .clipShape(Capsule())
                        .padding(.bottom, 100)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                SBDesktopDock(
                    apps: dockApps,
                    isEditing: isEditing,
                    draggedBundleID: dragState.draggedBundleID,
                    onTap: { app in handleTap(app: app, anchor: nil) },
                    onLongPress: { app in enterEditing(app: app) },
                    onDeleteTap: { app in appPendingDelete = app },
                    onDropIntoDock: { app in moveToDock(app) },
                    onDragOutOfDock: { app in moveToGrid(app) }
                )
                .padding(.horizontal, 12)
                SBHomeBar()
            }
        }
        .onAppear { reloadApps() }
        .onChange(of: deleteError?.localizedDescription) { _ in
            showingDeleteError = deleteError != nil
        }
        .alert("删除此 App", isPresented: Binding(
            get: { appPendingDelete != nil },
            set: { if !$0 { appPendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let app = appPendingDelete {
                    onDeleteApp?(app)
                    appPendingDelete = nil
                }
            }
        } message: {
            Text("将删除 App 本体、全部数据与钥匙串记录，此操作不可撤销")
        }
        .alert("删除失败", isPresented: $showingDeleteError) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(deleteError?.localizedDescription ?? "删除失败，请重试")
        }
        .sheet(isPresented: $showingDetail) {
            if let app = detailApp {
                NavigationView {
                    SBAppDetailView(
                        app: app,
                        onDeleteApp: { deleted in
                            showingDetail = false
                            detailApp = nil
                            appPendingDelete = deleted
                        },
                        onClose: {
                            showingDetail = false
                            detailApp = nil
                        },
                        deleteError: deleteError
                    )
                }
            }
        }
    }

    // MARK: - 壁纸
    private var wallpaperView: some View {
        Group {
            if let custom = customWallpaperImage {
                Image(uiImage: custom)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image("DefaultWallpaper")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .ignoresSafeArea()
    }

    private var customWallpaperImage: UIImage? {
        let suite = "group." + (Bundle.main.bundleIdentifier ?? "")
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suite) else {
            return nil
        }
        let path = container.appendingPathComponent("wallpaper.jpg").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return UIImage(contentsOfFile: path)
    }

    // MARK: - 排序与分页
    private var orderedApps: [SBInstalledApp] {
        let suite = "group." + (Bundle.main.bundleIdentifier ?? "")
        let order = UserDefaults(suiteName: suite)?.array(forKey: "SBDesktopIconOrder") as? [String] ?? []
        // 列表由 store 的 @Published 已装应用驱动（安装/删除后自动刷新）；
        // 首次出现前 reloadApps() 已调过 loadInstalledApps() 填充它。
        let loaded = store.installedApps
        // 平行安装会产生相同 Bundle ID 的两条记录：按首次出现去重，绝不 crash。
        var byID: [String: SBInstalledApp] = [:]
        for app in loaded where byID[app.bundleID] == nil {
            byID[app.bundleID] = app
        }
        var result = order.compactMap { byID[$0] }
        result += loaded.filter { !order.contains($0.bundleID) }
        return result
    }

    private var dockApps: [SBInstalledApp] {
        let suite = "group." + (Bundle.main.bundleIdentifier ?? "")
        let dockOrder = UserDefaults(suiteName: suite)?.array(forKey: "SBDesktopDockOrder") as? [String] ?? []
        var byID: [String: SBInstalledApp] = [:]
        for app in orderedApps where byID[app.bundleID] == nil {
            byID[app.bundleID] = app
        }
        return dockOrder.compactMap { byID[$0] }.prefix(4).map { $0 }
    }

    private var gridApps: [SBInstalledApp] {
        let dockIDs = Set(dockApps.map { $0.bundleID })
        return orderedApps.filter { !dockIDs.contains($0.bundleID) }
    }

    private var pages: [[SBInstalledApp]] {
        var result: [[SBInstalledApp]] = []
        var current: [SBInstalledApp] = []
        for app in gridApps {
            current.append(app)
            if current.count == appsPerPage {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        if result.isEmpty { result.append([]) }
        return result
    }

    private func gridPage(_ pageApps: [SBInstalledApp], page: Int) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return LazyVGrid(columns: columns, spacing: 20) {
            // 编辑态首格是“导入 IPA”的 + 格（其余页不重复）。
            if isEditing, page == 0 {
                Button(action: { onImport?() }) {
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 58 * 0.2667, style: .continuous)
                                .fill(Color.white.opacity(0.25))
                                .frame(width: 58, height: 58)
                            Image(systemName: "plus")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundColor(.white)
                        }
                        Text("导入")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                    }
                }
            }
            ForEach(Array(pageApps.enumerated()), id: \.element.bundleID) { index, app in
                let isPlaceholder = dragState.isDragging
                    && dragState.placeholderPage == page
                    && dragState.placeholderIndex == index
                ZStack {
                    if isPlaceholder {
                        RoundedRectangle(cornerRadius: 58 * 0.2667, style: .continuous)
                            .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 58, height: 58)
                    }
                    SBDesktopCell(
                        app: app,
                        iconSize: 58,
                        isEditing: isEditing,
                        isPlaceholder: isPlaceholder,
                        onTap: {
                            // 编辑态点按不启动：点按只进详情（长按拖动换位在 onLongPress）。
                            if isEditing { detailApp = app; showingDetail = true; return }
                            handleTap(app: app, anchor: nil)
                        },
                        onDeleteTap: { appPendingDelete = app },
                        onLongPress: { enterEditing(app: app) }
                    )
                    .rotationEffect(.degrees(isEditing ? (index % 2 == 0 ? -1.2 : 1.2) : 0))
                    .animation(isEditing ? .easeInOut(duration: 0.12).repeatForever(autoreverses: true) : .default, value: isEditing)
                    .gesture(dragGesture(for: app, page: page, index: index))
                }
            }
            // 占位格在末尾时补一个虚线空位。
            if dragState.isDragging, dragState.placeholderPage == page, dragState.placeholderIndex == pageApps.count {
                RoundedRectangle(cornerRadius: 58 * 0.2667, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 58, height: 58)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: - 拖动（搜索时禁用）
    private func dragGesture(for app: SBInstalledApp, page: Int, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isSearching, dragState.isLongPressArmed || dragState.isDragging else { return }
                if dragState.updateDrag(to: value.location) {
                    // 边缘 24pt 热区悬停 0.65s 翻页（状态机内部计时）。
                    // 此处用视图尺寸近似：横向热区由 SBDesktopDragState.edgePageDirection 判定，
                    // 调用方传入当前页尺寸时才翻页；简化实现：仅在占位换算时更新。
                    let targetIndex = indexForLocation(value.location, page: page, count: pages[page].count)
                    dragState.updatePlaceholder(page: page, index: targetIndex, hasValidTarget: true)
                }
            }
            .onEnded { _ in
                guard dragState.isDragging else {
                    dragState.disarmLongPress()
                    return
                }
                if let target = dragState.drop() {
                    withAnimation(.easeInOut(duration: SBDesktopDragState.dropDuration)) {
                        moveApp(app, toPage: target.page, index: target.index)
                    }
                } else {
                    // 无落点：0.45s 飞回原格（状态已清，Cell 回到原位即飞回效果）。
                    withAnimation(.easeInOut(duration: SBDesktopDragState.flyBackDuration)) {
                        dragState.flyBack()
                    }
                }
            }
    }

    private func indexForLocation(_ location: CGPoint, page: Int, count: Int) -> Int {
        // 简化换算：按 4 列网格从落点估算格序，夹在 0...count 之间。
        // 精确换算依赖 GeometryReader 的格坐标，由集成方在需要时替换。
        max(0, min(count, Int(location.y / 90) * 4 + Int(location.x / 90)))
    }

    // MARK: - 点按 / 证书门 / 启动
    private func handleTap(app: SBInstalledApp, anchor: CGPoint?) {
        if isEditing { return }
        // A2 证书门：无证书不做缩放动画，直接弹缺证书引导。
        if !SBCertificate.hasCertificate {
            onNeedCertificate?()
            return
        }
        zoomAnchor = anchor
        zoomingApp = app
        // 460ms 缩放结束后 SBLaunchZoom 的 onFinished 调 onLaunchApp。
        // 启动计数不在此加：由 GuestLoader 在启动结果落定后调
        // recordLaunchResult / incrementLaunchCount，避免失败也计数。
    }

    private func enterEditing(app: SBInstalledApp) {
        isEditing = true
        dragState.armLongPress(bundleID: app.bundleID, at: .zero)
    }

    // MARK: - 排序持久化
    private func moveApp(_ app: SBInstalledApp, toPage page: Int, index: Int) {
        var order = gridApps.map { $0.bundleID }
        order.removeAll { $0 == app.bundleID }
        let flatIndex = min(max(page * appsPerPage + index, 0), order.count)
        order.insert(app.bundleID, at: flatIndex)
        persistIconOrder(order + dockApps.map { $0.bundleID })
        reloadApps()
    }

    private func moveToDock(_ app: SBInstalledApp) {
        var dock = dockApps.map { $0.bundleID }
        guard !dock.contains(app.bundleID), dock.count < 4 else { return }
        dock.append(app.bundleID)
        persistDockOrder(dock)
        reloadApps()
    }

    private func moveToGrid(_ app: SBInstalledApp) {
        var dock = dockApps.map { $0.bundleID }
        dock.removeAll { $0 == app.bundleID }
        persistDockOrder(dock)
        reloadApps()
    }

    private func persistIconOrder(_ order: [String]) {
        let suite = "group." + (Bundle.main.bundleIdentifier ?? "")
        UserDefaults(suiteName: suite)?.set(order, forKey: "SBDesktopIconOrder")
    }

    private func persistDockOrder(_ order: [String]) {
        let suite = "group." + (Bundle.main.bundleIdentifier ?? "")
        let defaults = UserDefaults(suiteName: suite)
        defaults?.set(order, forKey: "SBDesktopDockOrder")
        defaults?.set(true, forKey: "SBDesktopDockManuallyEdited")
    }

    private func reloadApps() {
        // 先从 Store 拉最新列表（填 @Published，驱动 body 刷新），再做翻页越界钳制。
        SBStore.shared.loadInstalledApps()
        // 列表每次从 SBStore.shared.loadInstalledApps() 现取，不另缓存；
        // 这里只做翻页越界钳制（删 App 后页数变少时回到最后一页）。
        if currentPage >= pages.count {
            currentPage = max(pages.count - 1, 0)
        }
    }

    // MARK: - 通知中心（v1 不做）
    /// 下滑手势若落在通知中心区域：只回弹 + toast，不打开任何面板。
    private func showNotificationCenterUnavailable() {
        toastMessage = "通知中心 v1 未提供"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if toastMessage == "通知中心 v1 未提供" { toastMessage = nil }
        }
    }
}
