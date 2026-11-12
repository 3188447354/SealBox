//
//  ContentView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

class SearchContext: ObservableObject {
    @Published var query: String = ""
    @Published var debouncedQuery: String = ""
    @Published var isTyping: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        $query
            .debounce(for: .seconds(0.2), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isTyping = true
                self?.debouncedQuery = value
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.isTyping = false
                }
            }
            .store(in: &cancellables)
    }
}

struct AppReplaceOption : Hashable {
    var isReplace: Bool
    var nameOfFolderToInstall: String
    var appToReplace: LCAppModel?
}

struct LCAppListView : View, LCAppBannerDelegate, LCAppModelDelegate {
    @State var didAppear = false
    // ipa choosing stuff
    @State var choosingIPA = false
    @State var errorShow = false
    @State var errorInfo = ""
    
    // ipa installing stuff
    @State var installprogressVisible = false
    @State var installProgressPercentage : Float = 0.0
    @State var installObserver : NSKeyValueObservation?
    
    @State var installOptions: [AppReplaceOption]
    @StateObject var installReplaceAlert = AlertHelper<AppReplaceOption>()
    
    @State var webViewOpened = false
    @State var webViewURL : URL = URL(string: "about:blank")!
    @StateObject private var webViewUrlInput = InputHelper()
    
    @EnvironmentObject var downloadHelper: DownloadHelper
    @StateObject private var installUrlInput = InputHelper()
    
    @State private var jitLog = ""
    @StateObject private var jitAlert = YesNoHelper()
    
    @StateObject private var runWhenMultitaskAlert = YesNoHelper()
    
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()
    
    @State var safariViewOpened = false
    @State var safariViewURL = URL(string: "https://google.com")!
    
    // Kept for the LCAppBannerDelegate protocol (openNavigationView):
    // the banner rows are gone from the desktop, so nothing navigates
    // through these anymore; they are inert.
    @State private var navigateTo : AnyView?
    @State private var isNavigationActive = false
    
    
    @State private var customSortViewPresent = false
    
    @EnvironmentObject private var sharedModel : SharedModel
    @EnvironmentObject private var sharedAppSortManager : LCAppSortManager
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    
    @State private var isViewAppeared = false

    // MARK: - Desktop grid (v1)

    @Environment(\.scenePhase) private var scenePhase

    /// Edit / jiggle mode. Entered by long-pressing the desktop
    /// (0.45 s, demo §1.3). Exited by tapping blank desktop or the
    /// "···" menu's Done entry. There is no toolbar "✓" anymore: the
    /// home screen has no toolbar at all.
    @State private var isEditing = false
    /// When edit mode was entered (demo §2.5): a tap on blank desktop
    /// within 400 ms of entering does not exit edit mode.
    @State private var editingSince = Date.distantPast
    /// Floating search field, opened from the edit-mode "···" menu.
    /// It is not a permanent search bar: the desktop shows no search
    /// UI until the user asks for it.
    @State private var showSearchBar = false
    /// Keyboard focus for the floating search field.
    @FocusState private var searchFieldFocused: Bool
    /// Currently visible page (0-based). Drives the TabView selection
    /// and the custom page dots.
    @State private var currentPage = 0
    @StateObject private var desktopDrag = LCDesktopDragState()
    @StateObject private var desktopOrder = LCDesktopOrderStore()
    @StateObject private var desktopDock = LCDesktopDockStore()

    // MARK: - App switcher / home bar / control center (§10.2 / §11 / §13)

    /// Switcher cards (open multitask windows + open system page).
    @StateObject private var switcherStore = LCAppSwitcherStore()
    /// Home-bar gesture state: window scale + pending action.
    @StateObject private var homeBarState = LCSealBoxHomeBarState()
    /// Whether SealBox owns the bottom home-indicator gestures.
    @StateObject private var lockStore = LCSealBoxLockStore()
    @State private var showSwitcher = false
    @State private var showControlCenter = false

    // MARK: - Desktop wallpaper + theme

    @StateObject private var wallpaperStore = LCDesktopWallpaperStore()
    /// Desktop theme (system / dark / light). Stored in the App Group
    /// UserDefaults under "LCDesktopTheme"; the edit-mode "···" menu
    /// writes the same key. Wallpaper and theme are stored separately.
    @AppStorage("LCDesktopTheme", store: LCUtils.appGroupUserDefault) private var desktopTheme = LCDesktopTheme.system
    /// System photo picker (PHPicker) presentation. The picked image
    /// is applied immediately, as-is — there is no edit page.
    @State private var showWallpaperPicker = false
    /// "恢复默认壁纸" lives in the edit-mode "···" menu; tapping it
    /// asks for confirmation before deleting the stored custom
    /// wallpaper and going back to the bundled default.
    @State private var showRestoreWallpaperDialog = false

    /// App awaiting delete confirmation (grid "−" button).
    @State private var appPendingDelete: LCAppModel?
    @State private var deleteConfirmName = ""
    @State private var showDeleteConfirm = false

    /// System page opened from its desktop icon (full-screen cover).
    @State private var systemPage: LCSystemPage?
    /// Left-edge swipe-back on a system page: set while a drag that
    /// started within 24pt of the left edge is in progress.
    @State private var edgeSwipeFromLeft = false
    
    @ObservedObject var searchContext: SearchContext = SearchContext()
    var sortedApps: [LCAppModel] {
        return sharedAppSortManager.sortedApps
    }
    
    var sortedHiddenApps: [LCAppModel] {
        return sharedAppSortManager.sortedHiddenApps
    }
    
    var filteredApps: [LCAppModel] {
        let apps = sortedApps
        if searchContext.debouncedQuery.isEmpty {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    var filteredHiddenApps: [LCAppModel] {
        let apps = sortedHiddenApps
        if searchContext.debouncedQuery.isEmpty || !sharedModel.isHiddenAppUnlocked {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    init() {
        _installOptions = State(initialValue: [])
    }
    
    /// The desktop window itself: wallpaper, icon grid,
    /// page dots and the drag ghost, plus the home-bar
    /// shell transforms (shrink / corner radius / the
    /// control-centre trigger and lock-button overlays).
    /// Split out of `body` so the type checker sees a
    /// smaller expression per property: the whole body
    /// in one expression timed the checker out.
    private var desktopWindowView: some View {
        GeometryReader { geometry in
        ZStack {
            // Wallpaper fills the whole phone screen, behind everything
            // including the Dock area (the Dock is translucent).
            desktopBackgroundView

            VStack(spacing: 0) {
                // Top strip: edit-mode capsules, the floating search
                // field, the install progress pill. Empty in normal
                // mode — the desktop shows nothing but icons.
                // Edit-mode chrome (demo §2.3): fades/slides in with a
                // 0.34 s spring-pop when edit mode is entered. The
                // animation lives on this Group alone so it never
                // leaks into the grid cells' own animations.
                Group {
                    if isEditing {
                        editModeTopBar
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.34, dampingFraction: 0.6), value: isEditing)
                if showSearchBar {
                    searchFieldView
                }
                if installprogressVisible {
                    installProgressView
                }

                desktopPagesView
                desktopPageDots
            }
            .padding(.top, geometry.safeAreaInsets.top)
            // Tap the blank desktop to exit edit mode; triple-tap it
            // in normal mode to unlock hidden apps (the unlock gesture
            // used to live behind the old app-counter footer, which is
            // gone with the old list UI). The exit guard (demo §2.5):
            // a tap within 400 ms of entering edit mode does not exit
            // (it is the same press that just entered it).
            .onTapGesture {
                if isEditing, Date().timeIntervalSince(editingSince) >= 0.4 {
                    exitEditMode()
                }
            }
            .onTapGesture(count: 3) {
                if !isEditing {
                    Task { await authenticateUser() }
                }
            }
            // Long-press the blank desktop to enter edit mode (0.45 s,
            // demo §1.3).
            .onLongPressGesture(minimumDuration: 0.45) {
                enterEditMode()
            }

            // The drag ghost: the icon being dragged, floating above
            // the grid and following the finger 1:1 (demo §1.4). It is
            // the only child that hit-tests nothing, so it never eats
            // taps meant for the icons below it.
            if desktopDrag.isDragging || desktopDrag.isLanding,
               let ghostIcon = desktopDrag.draggedIcon {
                desktopDragGhost(for: ghostIcon)
                    .allowsHitTesting(false)
            }
        }
        // SealBox shell (§11 / §13): the whole desktop window shrinks
        // with the home-bar gesture (transforms on the desktop content
        // only — the trigger and lock button below are overlays attached
        // after them, so they stay put and keep receiving gestures).
        // The frame pins the overlay anchors to the full content area
        // above the Dock.
        // Layers (demo §7.1 / §8.3): while the switcher is open the
        // desktop sits at 0.92 / 0.5; otherwise it is the front window
        // and follows the finger (proportional shrink, not a slide-out,
        // demo §8.3: scale 1 − p·0.22, slight upward drift, corner
        // radius in 3 discrete steps). The corner clip is only applied
        // while the radius is > 0, so it never clips the wallpaper's
        // parallax overscan at rest.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(showSwitcher ? 0.92 : homeBarState.windowScale)
        .offset(y: showSwitcher ? 0 : homeBarState.windowOffsetY)
        .apply { content in
            if !showSwitcher, homeBarState.windowCornerRadius > 0 {
                content.clipShape(RoundedRectangle(cornerRadius: homeBarState.windowCornerRadius))
            } else {
                content
            }
        }
        .opacity(showSwitcher ? 0.5 : 1.0)
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: showSwitcher)
        .overlay(alignment: .topTrailing) {
            // Control-centre trigger: the top 44pt strip at the
            // trailing edge (§13). It sits over the status-bar area,
            // clear of the lock button and the edit-mode capsules,
            // which both live below the safe area.
            LCSealBoxControlCenterTrigger {
                showControlCenter = true
            }
        }
        .overlay(alignment: .topTrailing) {
            // Floating lock button: always on the desktop, hidden while
            // editing (§11; the edit-mode capsules own the corners
            // then). Kept below the 44pt trigger strip:
            // max(safeArea, 44) + 12 from the top.
            if !isEditing {
                LCSealBoxLockButton(lockStore: lockStore)
                    .padding(.top, max(geometry.safeAreaInsets.top, 44) + 12)
                    .padding(.trailing, 20)
            } else {
                EmptyView()
            }
        }
        }
    }

    /// Shell modifiers on the desktop window: coordinate
    /// spaces, drag frame reports, status bar, appear /
    /// change hooks, tab-bar hiding, colour scheme and
    /// the pinned home-bar strip and Dock.
    private var desktopShellView: some View {
        desktopWindowView
        .coordinateSpace(name: "scroll")
        // The "desktop" coordinate space: the drag gesture, the cell /
        // grid / Dock frame reports and the ghost all resolve in it, so
        // hit-testing and the ghost position share one origin (the
        // screen's top-left).
        .coordinateSpace(name: "desktop")
        // Drag hit-test frames (see LCDesktopDragState).
        .onPreferenceChange(LCDesktopCellFramePreferenceKey.self) { frames in
            desktopDrag.cellFrames = frames
        }
        .onPreferenceChange(LCDesktopGridFramePreferenceKey.self) { frames in
            desktopDrag.gridFrames = frames
        }
        .onPreferenceChange(LCDesktopDockFramePreferenceKey.self) { frames in
            desktopDrag.dockFrame = frames.bar
            desktopDrag.dockSlotFrames = frames.slots
        }
        // Status bar (demo §2.2): hidden in edit mode — the edit chrome
        // replaces it — and shown otherwise.
        .statusBar(hidden: isEditing)
        .onAppear {
            if !didAppear {
                onAppear()
            }
        }
        .onAppear {
            // Bring the persisted order / Dock up to date with the
            // installed apps.
            syncDesktopOrder()
            refreshDock()
        }
        .onChange(of: sharedModel.apps.count) { _ in
            syncDesktopOrder()
            refreshDock()
        }
        .onChange(of: sharedModel.hiddenApps.count) { _ in
            syncDesktopOrder()
            refreshDock()
        }
        .onChange(of: desktopPageCount) { _ in
            if currentPage >= desktopPageCount {
                currentPage = max(0, desktopPageCount - 1)
            }
        }
        .onChange(of: scenePhase) { phase in
            // A drag cancelled by backgrounding must not leave a
            // stale dragged icon behind.
            if phase != .active {
                desktopDrag.endDrag()
                // A home-bar gesture interrupted by the system (call,
                // backgrounding) must not leave a half-shrunk window
                // behind. resetToPreGesture is the hook the state
                // machine documents for scenePhase / disappear hooks
                // (it is cancelGesture under that name); only called
                // while a gesture is actually in flight, so an idle
                // backgrounding never fires a spurious spring-back.
                if homeBarState.isGestureActive {
                    homeBarState.resetToPreGesture()
                }
            }
        }
        .onChange(of: homeBarState.pendingAction) { action in
            // Home-bar actions are posted once by LCSealBoxHomeBarState
            // and cleared here (§11). Clear first, so the state
            // machine can post the next action while this one runs.
            guard let action else { return }
            homeBarState.pendingAction = nil
            switch action {
            case .goDesktop:
                // Back to the desktop: drop the switcher and any open
                // system page. The window scale is already restored by
                // the state machine (restoreWindow in endGesture /
                // fireSwitcher) before it posts the action, so there is
                // nothing to un-shrink here.
                exitEditMode()
                showSwitcher = false
                systemPage = nil
            case .openSwitcher:
                // Refresh from the real open-window registries first,
                // then show. The system-page cover (if any) must go
                // away too: the switcher is an overlay on the desktop,
                // so it would stay hidden behind the cover otherwise.
                // Entering the switcher exits edit mode (demo §2.5).
                exitEditMode()
                switcherStore.refresh(
                    apps: sharedModel.apps + sharedModel.hiddenApps,
                    tweakNames: sharedModel.tweakFolderNames,
                    openSystemPage: systemPage,
                    darkModeIcon: darkModeIcon
                )
                // The demo only enters the switcher when there is a
                // current app or recents; with no cards there is
                // nothing to switch to, so stay put.
                guard !switcherStore.cards.isEmpty else { return }
                systemPage = nil
                showSwitcher = true
            }
        }
        .hideDesktopTabBar()
        .preferredColorScheme(desktopTheme.colorScheme)
        // SealBox home bar (§11): its own 36pt strip directly above
        // the Dock. This inset is applied before the Dock's, so it sits
        // between the desktop content and the Dock — never overlapping
        // the page dots — and the pill is always drawn. Only while
        // locked does the strip take over the gestures; unlocked it
        // does not hit-test at all (see LCSealBoxHomeIndicatorView),
        // so Dock taps and the real system's Home gesture are untouched.
        .safeAreaInset(edge: .bottom) {
            LCSealBoxHomeIndicatorView(state: homeBarState, isLocked: lockStore.isLocked)
        }
        // The Dock is pinned to the bottom of the phone screen with
        // safeAreaInset: paging, dragging, searching and the keyboard
        // can never push it down, shrink it or hide it. Its height and
        // icon size are fixed in LCDesktopDockView. The keyboard safe
        // area is ignored at the bottom so the Dock never rides up
        // with the keyboard.
        .safeAreaInset(edge: .bottom) {
            LCDesktopDockView(
                dockIcons: dockDisplayIcons,
                isEditing: isEditing,
                isDragOver: desktopDrag.isOverDock,
                darkModeIcon: darkModeIcon,
                draggedID: desktopDrag.draggedID,
                dropTargetSlot: dockDropTargetSlot,
                onTapIcon: { icon in
                    desktopIconTapped(icon)
                },
                onDeleteIcon: { icon in
                    // Dock "−" removes the icon from the Dock only
                    // (it returns to the grid). It never deletes the
                    // app; app deletion is the grid "−" button.
                    removeIconFromDock(icon)
                },
                dragGestureFor: { icon in
                    desktopIconDragGesture(for: icon, isInDock: true)
                }
            )
            // Dock follow (demo §7.1 / §8.3): while the switcher is
            // open it sits at 0.96 / 0.55; while a system page is open
            // it fades in with the home-bar follow (scale 0.92 + p·0.08,
            // opacity p) as the page shrinks and reveals it. Otherwise
            // it is fixed (MEMORY: the Dock is never pushed, shrunk or
            // hidden by paging, dragging, searching or the keyboard).
            // The p-driven changes follow per-frame (no animation); the
            // state flips animate.
            .scaleEffect(dockLayerScale)
            .opacity(dockLayerOpacity)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: systemPage)
            .animation(.spring(response: 0.42, dampingFraction: 0.85), value: showSwitcher)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    /// Alerts, sheets, full-screen covers and dialogs
    /// on the desktop shell.
    private var desktopDialogsView: some View {
        desktopShellView
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
            Task { await startInstallApp(fileUrls[0]) }
        }, onDismiss: {
            choosingIPA = false
        })
        .alert("lc.appList.installation".loc, isPresented: $installReplaceAlert.show) {
            ForEach(installOptions, id: \.self) { installOption in
                Button(role: installOption.isReplace ? .destructive : nil, action: {
                    installReplaceAlert.close(result: installOption)
                }, label: {
                    Text(installOption.isReplace ? installOption.nameOfFolderToInstall : "lc.appList.installAsNew".loc)
                })
            
            }
            Button(role: .cancel, action: {
                installReplaceAlert.close(result: nil)
            }, label: {
                Text("lc.appList.abortInstallation".loc)
            })
        } message: {
            Text("lc.appList.installReplaceTip".loc)
        }
        .alert("lc.webView.runApp".loc, isPresented: $runWhenMultitaskAlert.show) {
            Button(role: .destructive) {
                runWhenMultitaskAlert.close(result: true)
            } label: {
                Text("lc.common.continue".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                runWhenMultitaskAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.confirmRunWhenMultitasking".loc)
        }
        .alert("lc.appList.generatedIconStyleSelector.title".loc, isPresented:$generatedIconStyleSelector.show) {
            Button {
                generatedIconStyleSelector.close(result: .Light)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.light".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Dark)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.dark".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Original)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.original".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                generatedIconStyleSelector.close(result: nil)
            }
        }
        .textFieldAlert(
            isPresented: $webViewUrlInput.show,
            title:  "lc.appList.enterUrlTip".loc,
            text: $webViewUrlInput.initVal,
            placeholder: "scheme://",
            action: { newText in
                webViewUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                webViewUrlInput.close(result: nil)
            }
        )
        .textFieldAlert(
            isPresented: $installUrlInput.show,
            title:  "lc.appList.installUrlInputTip".loc,
            text: $installUrlInput.initVal,
            placeholder: "https://",
            action: { newText in
                installUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                installUrlInput.close(result: nil)
            }
        )
        .sheet(isPresented: $jitAlert.show, onDismiss: {
            jitAlert.close(result: false)
        }) {
            JITEnablingModal
        }
        .onChange(of: jitAlert.show) { newValue in
            sharedModel.isJITModalOpen = newValue
        }
        .fullScreenCover(isPresented: $webViewOpened) {
            LCWebView(url: $webViewURL, isPresent: $webViewOpened, itmsServicesHandler: { urlStr in
                await installFromPlist(urlStr: urlStr)
            })
        }
        .fullScreenCover(isPresented: $safariViewOpened) {
            SafariView(url: $safariViewURL)
        }
        .sheet(isPresented: $customSortViewPresent) {
            LCCustomSortView()
        }
        // Wallpaper: system photo picker (single image). The picked
        // image is applied immediately, as-is — no edit page, no crop /
        // zoom / brightness / blur. LCDesktopWallpaperStore downscales
        // it when saving (see apply(image:)).
        .sheet(isPresented: $showWallpaperPicker) {
            LCPhotoPicker(isPresented: $showWallpaperPicker) { image in
                wallpaperStore.apply(image: image)
            }
        }
        .confirmationDialog("恢复默认壁纸", isPresented: $showRestoreWallpaperDialog) {
            Button("恢复默认壁纸", role: .destructive) {
                wallpaperStore.resetToDefault()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除自定义壁纸，恢复默认背景。")
        }
        .onAppear() {
            if !isViewAppeared {
                if let webpageUrlStr = UserDefaults.standard.string(forKey: "webPageToOpen") {
                    Task { await openWebView(urlString: webpageUrlStr) }
                    UserDefaults.standard.set(nil, forKey: "webPageToOpen")
                }
                
                guard sharedModel.selectedTab == .apps, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .apps, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
        .onDrop(of: [.url], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url else { return }
                Task {
                    guard let urlToOpen = await webViewUrlInput.open(initVal: url.absoluteString), urlToOpen != "" else {
                        return
                    }
                    await openWebView(urlString: urlToOpen)
                }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppNotification)) { obj in
            if let obj2 = obj.object as? [String: Any], let installUrl = obj2["url"] as? URL {
                Task { await installFromUrl(urlStr: installUrl.absoluteString) }
            }
        }
    }

    var body: some View {
        // SealBox is a virtual phone inside an app: the home screen is
        // a phone home screen, not an app list. No NavigationView, no
        // title, no search bar, no toolbar, no Tab Bar shell — just the
        // wallpaper, the icon grid, the page dots and the pinned Dock.
        // The LCTabView that hosts this view still exists as the app
        // root (it owns deep links, crash checks and the download
        // alert); its Tab Bar stays hidden here via
        // .hideDesktopTabBar() (iOS 16+; on iOS 15 it still shows —
        // known gap, see DESKTOP_GRID_V1.md).
        // The TabView page lays its content out edge-to-edge, so the
        // grid would start at y=0 under the status bar (MJ's 02:56
        // screenshot: the time was hidden behind the first row of
        // icons). Read the real safe-area inset and pad the content
        // below the status bar by exactly that much; the wallpaper
        // still fills the whole screen behind everything.
        desktopDialogsView
        .fullScreenCover(item: $systemPage) { page in
            // Full-screen cover (not a sheet, not a NavigationLink):
            // the three Views each embed their own NavigationView
            // (LCSourcesView:496, LCTweaksView:396, LCSettingsView:83),
            // which rules out NavigationLink (nested NavigationView),
            // and they are full app sections, not transient sheets.
            // The Done button in the navigation bar is the way back;
            // full-screen covers have no swipe-down dismiss.
            // Left-edge swipe-back is a second way back (Done stays):
            // a horizontal drag that STARTS within 24pt of the left
            // edge and travels right more than 46pt (and less than
            // 60pt vertically) dismisses the page (demo §10).
            // simultaneousGesture so the page's own vertical scrolling
            // keeps working; a drag starting anywhere else, or a
            // mostly-vertical drag, never dismisses. The gesture lives
            // only on this cover, so a right swipe on the desktop's
            // first page can never trigger it, and it is unrelated to
            // the desktop's edit-mode icon dragging.
            // The page is the front window for the home-bar follow
            // (demo §8.3): it shrinks proportionally with the finger
            // (scale 1 − p·0.22, slight upward drift, corner radius in
            // 3 discrete steps) while the desktop is revealed behind
            // it. The home-bar strip floats above the page (outside
            // the shrink) so it stays put.
            ZStack {
                page.view
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 30)
                            .onChanged { value in
                                if value.startLocation.x <= 24 {
                                    edgeSwipeFromLeft = true
                                }
                            }
                            .onEnded { value in
                                defer { edgeSwipeFromLeft = false }
                                guard edgeSwipeFromLeft else {
                                    return
                                }
                                if value.translation.width > 46
                                    && abs(value.translation.height) < 60 {
                                    systemPage = nil
                                }
                            }
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("lc.common.done".loc) {
                                systemPage = nil
                            }
                        }
                    }
                    .scaleEffect(homeBarState.windowScale)
                    .offset(y: homeBarState.windowOffsetY)
                    .apply { content in
                        if homeBarState.windowCornerRadius > 0 {
                            content.clipShape(RoundedRectangle(cornerRadius: homeBarState.windowCornerRadius))
                        } else {
                            content
                        }
                    }
            }
            // The home bar works on system pages too (§11): the
            // same 36pt strip, bottom-anchored over the page. It
            // floats above the page content like a real home
            // indicator; unlocked it does not hit-test, so the
            // page's own scrolling and taps are untouched.
            .overlay(alignment: .bottom) {
                LCSealBoxHomeIndicatorView(state: homeBarState, isLocked: lockStore.isLocked)
            }
        }
        .alert("lc.appBanner.confirmUninstallTitle".loc, isPresented: $showDeleteConfirm) {
            Button(role: .destructive) {
                if let app = appPendingDelete {
                    deleteDesktopApp(app)
                }
            } label: {
                Text("lc.appBanner.uninstall".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
            }
        } message: {
            Text("lc.appBanner.confirmUninstallMsg %@".localizeWithFormat(deleteConfirmName))
        }
        // SealBox shell overlays (§10.2 / §13). Both are overlays on
        // the desktop — not fullScreenCovers — so they never fight the
        // system-page cover for presentation: opening a system page
        // from the switcher (or Settings from the control centre) is
        // just two state flips in the same transaction, with no
        // dismiss-then-present race. They sit last, so they cover the
        // desktop, the home-bar strip and the Dock while open.
        .overlay {
            if showSwitcher {
                LCAppSwitcherView(
                    store: switcherStore,
                    darkModeIcon: darkModeIcon,
                    onDismiss: {
                        showSwitcher = false
                    },
                    onOpenSystem: { page in
                        showSwitcher = false
                        systemPage = page
                    }
                )
                // Entry/exit fade (demo §7.1/§7.4: the scrim fades
                // 0.42 s; the cards stagger in inside the switcher).
                .transition(.opacity)
            } else {
                EmptyView()
            }
        }
        .animation(.easeOut(duration: 0.42), value: showSwitcher)
        .overlay {
            if showControlCenter {
                LCSealBoxControlCenterView(
                    onDismiss: {
                        showControlCenter = false
                    },
                    onOpenSettings: {
                        showControlCenter = false
                        systemPage = .settings
                    }
                )
                // Open/close (demo §6/§11.1): the panel slides in
                // from the top and fades, 0.58 s spring-sheet.
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
            } else {
                EmptyView()
            }
        }
        .animation(.spring(response: 0.58, dampingFraction: 0.8), value: showControlCenter)
    }
    
    var JITEnablingModal : some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    Text("lc.appBanner.waitForJitMsg".loc)
                        .padding(.vertical)
                        .id(0)
                    
                    HStack {
                        Text(jitLog)
                            .font(.system(size: 12).monospaced())
                            .fixedSize(horizontal: false, vertical: false)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .onAppear {
                    proxy.scrollTo(0)
                }
            }
            .navigationTitle("lc.appBanner.waitForJitTitle".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc, role: .cancel) {
                        jitAlert.close(result: false)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        jitAlert.close(result: true)
                    } label: {
                        Text("lc.appBanner.jitLaunchNow".loc)
                    }
                }
            }
        }
    }
    
    func onOpenWebViewTapped() async {
        guard let urlToOpen = await webViewUrlInput.open(), urlToOpen != "" else {
            return
        }
        await openWebView(urlString: urlToOpen)
        
    }
    func onAppear() {
        for app in sharedModel.apps {
            app.delegate = self
        }
        for app in sharedModel.hiddenApps {
            app.delegate = self
        }
        didAppear = true
    }
    
    
    func openWebView(urlString: String) async {
        guard var urlToOpen = URLComponents(string: urlString), urlToOpen.url != nil else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        if urlToOpen.scheme == nil || urlToOpen.scheme! == "" {
            urlToOpen.scheme = "https"
        }
        
        if urlToOpen.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: urlString)
            return
        }
        
        if urlToOpen.scheme != "https" && urlToOpen.scheme != "http" {
            var appToLaunch : LCAppModel? = nil
            var appListsToConsider = [sharedModel.apps]
            if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                appListsToConsider.append(sharedModel.hiddenApps)
            }
            appLoop:
            for appList in appListsToConsider {
                for app in appList {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == urlToOpen.scheme {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
            }


            guard let appToLaunch = appToLaunch else {
                errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(urlToOpen.scheme!)
                errorShow = true
                return
            }
            
            if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    return
                }
            }
            
            do {
                try await appToLaunch.runApp(urlStr: urlToOpen.url!.absoluteString)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            return
        }
        webViewURL = urlToOpen.url!
        if webViewOpened {
            webViewOpened = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                webViewOpened = true
            })
        } else {
            webViewOpened = true
        }
    }


    
    func startInstallApp(_ fileUrl:URL) async {
        do {
            self.installprogressVisible = true
            try await installIpaFile(fileUrl)
            try FileManager.default.removeItem(at: fileUrl)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            self.installprogressVisible = false
            if #available(iOS 16.2, *) {
                Task { await LCContainerLiveActivityManager.endNow() }
            }
        }
    }
    
    nonisolated func decompress(_ path: String, _ destination: String ,_ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }
    
    func installIpaFile(_ url:URL) async throws {
        let fm = FileManager()

        // Container's own Live Activity: IPA install progress.
        if #available(iOS 16.2, *) {
            LCContainerLiveActivityManager.startInstall(appName: url.deletingPathExtension().lastPathComponent)
        }
        
        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        self.installProgressPercentage = 0.0
        self.installObserver = installProgress.observe(\.fractionCompleted) { p, v in
            DispatchQueue.main.async {
                self.installProgressPercentage = Float(p.fractionCompleted)
                if #available(iOS 16.2, *) {
                    LCContainerLiveActivityManager.updateProgress(Double(p.fractionCompleted), statusText: "lc.appList.installation".loc)
                }
            }
        }
        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        installProgress.addChild(decompressProgress, withPendingUnitCount: 80)
        let payloadPath = fm.temporaryDirectory.appendingPathComponent("Payload")
        if fm.fileExists(atPath: payloadPath.path) {
            try fm.removeItem(at: payloadPath)
        }
        
        // decompress
        guard await decompress(url.path, fm.temporaryDirectory.path, decompressProgress) == 0 else {
            throw "lc.appList.urlFileIsNotIpaError".loc
        }

        let payloadContents = try fm.contentsOfDirectory(atPath: payloadPath.path)
        var appBundleName : String? = nil
        for fileName in payloadContents {
            if fileName.hasSuffix(".app") {
                appBundleName = fileName
                break
            }
        }
        guard let appBundleName = appBundleName else {
            throw "lc.appList.bundleNotFondError".loc
        }

        let appFolderPath = payloadPath.appendingPathComponent(appBundleName)
        
        guard let newAppInfo = LCAppInfo(bundlePath: appFolderPath.path) else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }

        var appRelativePath = "\(newAppInfo.bundleIdentifier()!.sanitizeNonACSII()).app"
        var outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
        var appToReplace : LCAppModel? = nil
        // Folder exist! show alert for user to choose which bundle to replace
        var sameBundleIdApp = sharedModel.apps.filter { app in
            return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
        }
        if sameBundleIdApp.count == 0 {
            sameBundleIdApp = sharedModel.hiddenApps.filter { app in
                return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
            }
            
            // we found a hidden app, we need to authenticate before proceeding
            if sameBundleIdApp.count > 0 && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        self.installprogressVisible = false
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    self.installprogressVisible = false
                    return
                }
            }
            
        }
        
        if fm.fileExists(atPath: outputFolder.path) || sameBundleIdApp.count > 0 {
            appRelativePath = "\(newAppInfo.bundleIdentifier()!)_\(Int(CFAbsoluteTimeGetCurrent())).app"
            
            self.installOptions = [AppReplaceOption(isReplace: false, nameOfFolderToInstall: appRelativePath)]
            
            for app in sameBundleIdApp {
                self.installOptions.append(AppReplaceOption(isReplace: true, nameOfFolderToInstall: app.appInfo.relativeBundlePath, appToReplace: app))
            }

            guard let installOptionChosen = await installReplaceAlert.open() else {
                // user cancelled
                self.installprogressVisible = false
                try fm.removeItem(at: payloadPath)
                return
            }
            
            if let appToReplace = installOptionChosen.appToReplace, appToReplace.uiIsShared {
                outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            } else {
                outputFolder = LCPath.bundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            }
            appRelativePath = installOptionChosen.nameOfFolderToInstall
            appToReplace = installOptionChosen.appToReplace
            if installOptionChosen.isReplace {
                try fm.removeItem(at: outputFolder)
            }
        }
        // Move it!
        try fm.moveItem(at: appFolderPath, to: outputFolder)
        let finalNewApp = LCAppInfo(bundlePath: outputFolder.path)
        finalNewApp?.relativeBundlePath = appRelativePath
        
        guard let finalNewApp else {
            errorInfo = "lc.appList.appInfoInitError".loc
            errorShow = true
            return
        }
        
        // patch and sign it
        var signError : String? = nil
        var signSuccess = false
        await withUnsafeContinuation({ c in
            if appToReplace?.uiDontSign ?? false || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
                finalNewApp.dontSign = true
            }
            finalNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error
                signSuccess = success
                c.resume()
            }, progressHandler: { signProgress in
                installProgress.addChild(signProgress!, withPendingUnitCount: 20)
            }, forceSign: false)
        })
        
        // we leave it unsigned even if signing failed
        if let signError {
            if signSuccess {
                errorInfo = "\("lc.appList.signSuccessWithError".loc)\n\n\(signError)"
            } else {
                errorInfo = signError.loc
            }
            errorShow = true
        }
        
        if let appToReplace {
            // copy previous configration to new app
            finalNewApp.autoSaveDisabled = true
            finalNewApp.isLocked = appToReplace.appInfo.isLocked
            finalNewApp.isHidden = appToReplace.appInfo.isHidden
            finalNewApp.isJITNeeded = appToReplace.appInfo.isJITNeeded
            finalNewApp.isShared = appToReplace.appInfo.isShared
            finalNewApp.spoofSDKVersion = appToReplace.appInfo.spoofSDKVersion
            finalNewApp.doSymlinkInbox = appToReplace.appInfo.doSymlinkInbox
            finalNewApp.containerInfo = appToReplace.appInfo.containerInfo
            finalNewApp.tweakFolder = appToReplace.appInfo.tweakFolder
            finalNewApp.selectedLanguage = appToReplace.appInfo.selectedLanguage
            finalNewApp.dataUUID = appToReplace.appInfo.dataUUID
            finalNewApp.orientationLock = appToReplace.appInfo.orientationLock
            finalNewApp.dontInjectTweakLoader = appToReplace.appInfo.dontInjectTweakLoader
            finalNewApp.hideLiveContainer = appToReplace.appInfo.hideLiveContainer
            finalNewApp.dontLoadTweakLoader = appToReplace.appInfo.dontLoadTweakLoader
            finalNewApp.doUseLCBundleId = appToReplace.appInfo.doUseLCBundleId
            finalNewApp.fixFilePickerNew = appToReplace.appInfo.fixFilePickerNew
            finalNewApp.fixLocalNotification = appToReplace.appInfo.fixLocalNotification
            finalNewApp.lastLaunched = appToReplace.appInfo.lastLaunched
            finalNewApp.jitLaunchScriptJs = appToReplace.appInfo.jitLaunchScriptJs
            finalNewApp.multitaskSpecified = appToReplace.appInfo.multitaskSpecified
            finalNewApp.classicMode = appToReplace.appInfo.classicMode
            finalNewApp.autoSaveDisabled = false
            finalNewApp.save()
        } else {
            // enable SDK version spoof by defalut
            finalNewApp.spoofSDKVersion = true
        }
        finalNewApp.installationDate = Date.now
        
        DispatchQueue.main.async {
            if let appToReplace {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                
                if appToReplace.uiIsHidden {
                    sharedModel.hiddenApps.removeAll { $0 == appToReplace }
                    sharedModel.hiddenApps.append(newAppModel)
                } else {
                    sharedModel.apps.removeAll { $0 == appToReplace }
                    sharedModel.apps.append(newAppModel)
                }

            } else {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                sharedModel.apps.append(newAppModel)
                
                // add url schemes
                if let urlSchemes = finalNewApp.urlSchemes(), urlSchemes.count > 0 {
                    UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                        .addObjects(from: urlSchemes as! [Any])
                }
            }

            self.installprogressVisible = false
            if #available(iOS 16.2, *) {
                LCContainerLiveActivityManager.finish(statusText: "lc.common.done".loc)
            }
        }
    }
    
    func startInstallFromUrl() async {
        guard let installUrlStr = await installUrlInput.open(), installUrlStr.count > 0 else {
            return
        }
        if let url = URL(string:installUrlStr), url.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: installUrlStr)
            return
        }
        await installFromUrl(urlStr: installUrlStr)
    }
    
    func installFromPlist(urlStr: String) async {
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        var plistUrlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                errorInfo = "lc.appList.plistInvalidError".loc
                errorShow = true
                return
            }
        }
        
        guard let plistUrl = URL(string: plistUrlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: plistUrl)
            
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                errorInfo = "lc.appList.plistParseError".loc
                errorShow = true
                return
            }
            
            var ipaUrlStr: String?
            for asset in assets {
                if let kind = asset["kind"] as? String, kind == "software-package",
                   let url = asset["url"] as? String {
                    ipaUrlStr = url
                    break
                }
            }
            
            guard let ipaUrlStr else {
                errorInfo = "lc.appList.plistNoIpaError".loc
                errorShow = true
                return
            }
            
            await installFromUrl(urlStr: ipaUrlStr)
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func installFromUrl(urlStr: String) async {
        // ignore any install request if we are installing another app
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        guard var installUrl = URL(string: urlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        self.installprogressVisible = true
        defer {
            self.installprogressVisible = false
        }
        
        if installUrl.isFileURL {
            // install from local, we directly call local install method
            let fileExtension = installUrl.pathExtension.lowercased()
            if fileExtension != "ipa" && fileExtension != "tipa" {
                errorInfo = "lc.appList.urlFileIsNotIpaError".loc
                errorShow = true
                return
            }
            
            let fm = FileManager.default
            var didStartAccessing = false
            if !fm.isReadableFile(atPath: installUrl.path),
               let bookmarkData = LCUtils.appGroupUserDefault.data(forKey: "LCLaunchExtensionFileBookmark") {
                do {
                    var isStale = false
                    let resolvedURL = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: URL.BookmarkResolutionOptions(rawValue: 1 << 10),
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    installUrl = resolvedURL
                    didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                } catch {
                    errorInfo =  "Failed to resolve shared IPA bookmark: \(error.localizedDescription)"
                    errorShow = true
                    return
                }
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                didStartAccessing = installUrl.startAccessingSecurityScopedResource()
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                errorInfo = "lc.appList.ipaAccessError".loc
                errorShow = true
                return
            }
            
            defer {
                if didStartAccessing {
                    installUrl.stopAccessingSecurityScopedResource()
                }
            }
            
            do {
                try await installIpaFile(installUrl)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            do {
                // delete ipa if it's in inbox
                var shouldDelete = false
                if let documentsDirectory = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let inboxURL = documentsDirectory.appendingPathComponent("Inbox")
                    shouldDelete = installUrl.deletingLastPathComponent().standardizedFileURL == inboxURL.standardizedFileURL
                }
                if shouldDelete {
                    try fm.removeItem(at: installUrl)
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            return
        }
        
        do {
            let fileManager = FileManager.default
            let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(installUrl.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            
            try await downloadHelper.download(url: installUrl, to: destinationURL)
            if downloadHelper.cancelled {
                return
            }
            try await installIpaFile(destinationURL)
            try fileManager.removeItem(at: destinationURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    // MARK: - Desktop grid (v1) helpers

    /// Icons per page: 4 columns x 6 rows, Dock excluded.
    static let desktopIconsPerPage = 24

    var desktopGridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
    }

    var isSearching: Bool {
        !searchContext.debouncedQuery.isEmpty
    }

    /// All icons that belong on the desktop, unfiltered by search:
    /// IPA apps (visible + hidden per the hiding rules) + the three
    /// system icons. Sources / Tweaks are hidden when multiLCStatus == 2,
    /// mirroring the tab conditions in LCTabView.
    var desktopAllIconsUnfiltered: [LCDesktopIcon] {
        var icons: [LCDesktopIcon] = []
        for app in sortedApps {
            icons.append(.app(app))
        }
        if !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") || sharedModel.isHiddenAppUnlocked {
            for app in sortedHiddenApps {
                icons.append(.app(app))
            }
        }
        for page in LCSystemPage.allCases {
            if (page == .sources || page == .tweaks) && sharedModel.multiLCStatus == 2 {
                continue
            }
            icons.append(.system(page))
        }
        return icons
    }

    /// All icon ids (unfiltered). Used to sync the persisted order; the
    /// sync must never see the search filter, or a search would prune
    /// non-matching apps out of the order.
    var desktopAllIDs: [String] {
        desktopAllIconsUnfiltered.map { $0.id }
    }

    /// Icons as the user sees them on the grid: the persisted order,
    /// filtered by the current search (system icons are hidden while
    /// searching), excluding Dock members (a Dock icon is not duplicated
    /// in the grid, iPhone-style).
    var desktopVisibleIcons: [LCDesktopIcon] {
        // Search-aware source list.
        var sourceIcons: [LCDesktopIcon] = []
        for app in filteredApps {
            sourceIcons.append(.app(app))
        }
        if !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") || sharedModel.isHiddenAppUnlocked {
            for app in filteredHiddenApps {
                sourceIcons.append(.app(app))
            }
        }
        if !isSearching {
            for page in LCSystemPage.allCases {
                if (page == .sources || page == .tweaks) && sharedModel.multiLCStatus == 2 {
                    continue
                }
                sourceIcons.append(.system(page))
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: sourceIcons.map { ($0.id, $0) })
        let dockIDs = Set(desktopDock.dockIDs)
        var visible = desktopOrder.order.compactMap { byID[$0] }.filter { !dockIDs.contains($0.id) }
        // Icons not yet in the persisted order (e.g. installed before
        // the next sync) go at the end rather than vanishing.
        for icon in sourceIcons where !desktopOrder.order.contains(icon.id) && !dockIDs.contains(icon.id) {
            visible.append(icon)
        }
        return visible
    }

    /// Icons currently in the Dock, in Dock order. Apps only: a
    /// system icon that an older build persisted in the Dock is
    /// dropped here (and purged from the store on launch); it stays
    /// in the grid.
    var dockDisplayIcons: [LCDesktopIcon] {
        let byID = Dictionary(uniqueKeysWithValues: desktopAllIconsUnfiltered.map { ($0.id, $0) })
        return desktopDock.dockIDs.compactMap { byID[$0] }.filter { !$0.isSystem }
    }

    /// Ids of imported IPA apps only (no system icons). Used for the
    /// Dock's initial fill: the Dock never holds system icons.
    var desktopAppIDs: [String] {
        desktopAllIconsUnfiltered.compactMap { $0.appModel != nil ? $0.id : nil }
    }

    var desktopPages: [[LCDesktopIcon]] {
        let icons = desktopVisibleIcons
        guard !icons.isEmpty else {
            return []
        }
        var pages: [[LCDesktopIcon]] = []
        var index = 0
        while index < icons.count {
            let end = min(index + Self.desktopIconsPerPage, icons.count)
            pages.append(Array(icons[index..<end]))
            index = end
        }
        return pages
    }

    /// Live page count: ceil(total icons / 24). Never hardcoded.
    /// In edit mode the demo (§1.6) appends an extra trailing blank
    /// page whenever the last page is non-empty, so an icon can always
    /// be dragged onto a fresh page. It disappears on exiting edit
    /// mode (the current page clamps back via the onChange above).
    /// The grid size stays 24/page (MEMORY.md: 4 columns × 6 rows);
    /// the demo's 16/page is not adopted.
    var desktopPageCount: Int {
        let base = max(1, desktopPages.count)
        if isEditing, let last = desktopPages.last, !last.isEmpty {
            return base + 1
        }
        return base
    }

    // MARK: Desktop grid views

    /// The desktop background: the current wallpaper (custom, or the
    /// bundled default) plus the theme's dimming on top. Display follows
    /// a real phone home screen: centred, aspect fill — the image is
    /// scaled and cropped to the screen, whatever its shape (landscape /
    /// portrait / square) and whatever the device size. No stretching, no
    /// blank edges, nothing for the user to tune.
    private var desktopBackgroundView: some View {
        Group {
            if let wallpaper = wallpaperStore.image {
                Image(uiImage: wallpaper)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Overscan (demo §5): the image extends 14 pt past
                    // the screen on every side so the parallax shift
                    // never exposes an edge, plus a permanent 1.04× so
                    // the shift has room to pan.
                    .padding(-14)
                    .overlay(desktopTheme.wallpaperDim)
                    .clipped()
                    .ignoresSafeArea()
                    .scaleEffect(1.04)
                    // Parallax (demo §3): −12 pt per page, 0.55 s
                    // spring-snap. (The live −0.04×dx follow during a
                    // page swipe is not available: the system TabView
                    // does not expose the finger's offset.)
                    .offset(x: -CGFloat(currentPage) * 12)
                    .animation(.spring(response: 0.55, dampingFraction: 0.75), value: currentPage)
                    // Wallpaper change (demo §5): crossfade, opacity
                    // 0.4 s. The view's identity is keyed on the
                    // store's version so a new image fades in.
                    .id(wallpaperStore.version)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.4), value: wallpaperStore.version)
            }
        }
        // Pinned to the screen size: the −14 pt overscan above must
        // overflow (it is the parallax room), never grow the desktop
        // layout and push the grid up.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var desktopPagesView: some View {
        // TabView + .page: chosen over a horizontal ScrollView because
        // paging, selection binding (for the dots) and swipe-to-flip work
        // on the iOS 15 deployment target; ScrollView paging needs the
        // iOS 17 scrollTarget APIs. System page dots are disabled
        // (.never): custom dots are drawn below, centred above the Dock.
        TabView(selection: $currentPage) {
            ForEach(0..<desktopPageCount, id: \.self) { page in
                desktopPageGrid(page: page)
                    .tag(page)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private func desktopPageGrid(page: Int) -> some View {
        let icons = page < desktopPages.count ? desktopPages[page] : []
        return LazyVGrid(columns: desktopGridColumns, spacing: 18) {
            ForEach(icons, id: \.id) { icon in
                LCDesktopGridCell(
                    icon: icon,
                    isEditing: isEditing,
                    isDragged: desktopDrag.draggedID == icon.id,
                    isDropTarget: desktopDrag.dropTarget == .cell(id: icon.id),
                    darkModeIcon: darkModeIcon,
                    theme: desktopTheme,
                    onTap: {
                        desktopIconTapped(icon)
                    },
                    onDelete: icon.isDeletable ? {
                        requestDelete(icon)
                    } : nil
                )
                .apply { cell in
                    // Dragging is disabled while searching: a search
                    // shows a filtered subset, and reordering a subset
                    // would corrupt the persisted full order. Otherwise
                    // the icon carries the long-press → drag gesture
                    // (demo §1.4): it attaches on pointerdown
                    // regardless of edit mode, so the finger that
                    // long-pressed into edit mode can keep moving and
                    // drag without lifting. SwiftUI's onDrag / onDrop
                    // cannot do this — onDrag's internal press
                    // recogniser claims the touch before the long-press
                    // fires — so the drag is implemented by hand (see
                    // LCDesktopDrag.swift).
                    if isSearching {
                        cell
                    } else {
                        cell.gesture(desktopIconDragGesture(for: icon, isInDock: false))
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Grid frame for the drag hit-test: a drag over a page's blank
        // area lands at the end of that page.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LCDesktopGridFramePreferenceKey.self,
                    value: [page: proxy.frame(in: .named("desktop"))]
                )
            }
        )
    }

    /// Custom page dots (not the system PageTabViewStyle dots: the system
    /// dots' style and position cannot be guaranteed to sit above the
    /// Dock, and they are not tappable). Centred above the Dock; current
    /// page is a bright solid dot, others gray; tappable to jump; hidden
    /// when there is only one page. Demo §3: 8 pt dots, 7 pt gap, each
    /// dot in a padded tap target (6×2 pt), colour transition 0.3 s
    /// spring-open. The active dot does not scale in the demo.
    private var desktopPageDots: some View {
        Group {
            if desktopPageCount > 1 {
                HStack(spacing: 7) {
                    ForEach(0..<desktopPageCount, id: \.self) { page in
                        Button {
                            withAnimation {
                                currentPage = page
                            }
                        } label: {
                            Circle()
                                .fill(page == currentPage ? Color.primary : Color.secondary.opacity(0.5))
                                .frame(width: 8, height: 8)
                                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: currentPage)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    /// Edit-mode top capsules (v7): "+" top-left opens the .ipa/.tipa
    /// importer; "···" top-right opens the menu (wallpaper, theme,
    /// search, sort, restore default, done). Only visible in edit mode;
    /// in normal mode the desktop shows no buttons at all.
    private var editModeTopBar: some View {
        HStack {
            Button {
                choosingIPA = true
            } label: {
                Text("+")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.ultraThinMaterial))
            }
            Spacer()
            Menu {
                Button {
                    showWallpaperPicker = true
                } label: {
                    Label("壁纸", systemImage: "photo")
                }
                Picker("主题色", selection: $desktopTheme) {
                    ForEach(LCDesktopTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                Button {
                    showSearchBar = true
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                Picker("排序", selection: $sharedAppSortManager.appSortType) {
                    ForEach(AppSortType.allCases, id: \.self) { sortType in
                        Label(sortType.displayName, systemImage: sortType.systemImage)
                            .tag(sortType)
                    }
                }
                .onChange(of: sharedAppSortManager.appSortType) { newValue in
                    if sharedAppSortManager.appSortType == .custom {
                        customSortViewPresent = true
                    }
                }
                if sharedAppSortManager.appSortType == .custom {
                    Button {
                        customSortViewPresent = true
                    } label: {
                        Label("lc.appList.sort.customManage".loc, systemImage: "slider.horizontal.3")
                    }
                }
                Divider()
                Button("恢复默认壁纸", role: .destructive) {
                    showRestoreWallpaperDialog = true
                }
                Button("完成") {
                    exitEditMode()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThinMaterial))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    /// Floating search field, opened from the edit-mode "···" menu.
    /// The grid filters by searchContext.debouncedQuery (the same
    /// filter the old permanent search bar fed); dragging stays
    /// disabled while searching, and system icons are hidden while
    /// searching.
    private var searchFieldView: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索", text: $searchContext.query)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($searchFieldFocused)
                .onAppear {
                    // The field opens focused so the keyboard is already
                    // up; the Dock stays pinned (keyboard safe area is
                    // ignored at the bottom) and is never covered.
                    searchFieldFocused = true
                }
            if !searchContext.query.isEmpty {
                Button {
                    searchContext.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            Button("取消") {
                searchContext.query = ""
                showSearchBar = false
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    /// Install progress pill, shown at the top while an IPA is
    /// installing. Replaces the old navigation-bar progress bar, which
    /// went away with the NavigationView.
    private var installProgressView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
            Text("\(Int(installProgressPercentage * 100))%")
                .font(.footnote)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
        .padding(.top, 12)
    }

    /// Enters edit mode and records the entry time (the 400 ms
    /// exit guard, demo §2.5). All entry paths go through here:
    /// long-press on blank desktop, on an icon, or on a Dock icon.
    private func enterEditMode() {
        guard !isEditing else { return }
        isEditing = true
        editingSince = Date()
    }

    /// Exits edit mode: stops jiggling and dragging, hides the search
    /// field and clears the query.
    private func exitEditMode() {
        isEditing = false
        desktopDrag.endDrag()
        showSearchBar = false
        searchContext.query = ""
    }

    // MARK: Desktop grid actions

    func syncDesktopOrder() {
        let dockIDs = Set(desktopDock.dockIDs)
        desktopOrder.sync(allIDs: desktopAllIDs.filter { !dockIDs.contains($0) })
        if currentPage >= desktopPageCount {
            currentPage = max(0, desktopPageCount - 1)
        }
    }

    func flipPage(_ direction: LCDesktopEdgeDirection) {
        // Page-transition spring (demo §3): 0.52 s spring-snap.
        // The page glides instead of snapping when an edge hover
        // flips it mid-drag.
        withAnimation(.spring(response: 0.52, dampingFraction: 0.75)) {
            switch direction {
            case .previous:
                currentPage = max(0, currentPage - 1)
            case .next:
                currentPage = min(desktopPageCount - 1, currentPage + 1)
            }
        }
    }

    /// Dock initial fill from launch counts. Only while the user has never
    /// dragged anything: once manually edited, manual order wins and this
    /// is a no-op. Icons leaving the Dock return to the grid; icons
    /// entering the Dock leave the grid (no duplication).
    func refreshDock() {
        guard !desktopDock.manuallyEdited else {
            return
        }
        let top = LCDesktopLaunchCountStore.topIDs(
            limit: LCDesktopDockStore.maxDockItems,
            fallbackOrder: desktopAppIDs
        )
        let oldDock = desktopDock.dockIDs
        desktopDock.autoFill(topIDs: top)
        for id in oldDock where !desktopDock.dockIDs.contains(id) {
            if !desktopOrder.order.contains(id) {
                desktopOrder.insert(id: id, at: desktopOrder.order.count)
            }
        }
        for id in desktopDock.dockIDs {
            desktopOrder.remove(id: id)
        }
    }

    func desktopIconTapped(_ icon: LCDesktopIcon) {
        switch icon {
        case .app(let model):
            launchDesktopApp(model)
        case .system(let page):
            systemPage = page
        }
    }

    /// Launch a guest app from the grid or the Dock: record the launch
    /// (feeds the Dock's most-used ranking), show the container's own
    /// "launching" Live Activity, run, then finish the activity.
    func launchDesktopApp(_ app: LCAppModel) {
        let id = LCDesktopIcon.appID(for: app)
        LCDesktopLaunchCountStore.recordLaunch(id: id)
        if #available(iOS 16.2, *) {
            LCContainerLiveActivityManager.startLaunching(appName: app.displayName)
        }
        Task {
            if app.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        if #available(iOS 16.2, *) {
                            await LCContainerLiveActivityManager.endNow()
                        }
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    if #available(iOS 16.2, *) {
                        await LCContainerLiveActivityManager.endNow()
                    }
                    return
                }
            }
            do {
                try await app.runApp()
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            if #available(iOS 16.2, *) {
                LCContainerLiveActivityManager.finish(statusText: "lc.common.done".loc)
            }
            await MainActor.run {
                refreshDock()
            }
        }
    }

    func requestDelete(_ icon: LCDesktopIcon) {
        guard let model = icon.appModel else {
            return
        }
        appPendingDelete = model
        deleteConfirmName = model.displayName
        showDeleteConfirm = true
    }

    /// Grid "−" delete: a real uninstall, not just removing the model
    /// from the list. Reuses LCAppModel.uninstallFiles — the same code
    /// the banner's uninstall() uses — so the grid deletes exactly the
    /// same paths: the app bundle folder, every data container folder
    /// of this app, its keychain items, and its DataManager registry
    /// entry. The single confirmation dialog (confirmUninstallTitle /
    /// confirmUninstallMsg) covers bundle + data + keychain together.
    /// If file deletion fails, nothing is removed from the desktop and
    /// the error is shown instead. Shared apps are refused here as a
    /// second line of defence (the grid shows no "−" for them at all).
    /// After a successful delete, the desktop order, Dock and page
    /// dots update from the order change; the current page clamps
    /// itself via the existing .onChange(of: desktopPageCount), so
    /// deleting the last item on the last page drops that page.
    func deleteDesktopApp(_ app: LCAppModel) {
        guard !app.uiIsShared else {
            appPendingDelete = nil
            return
        }
        do {
            try LCAppModel.uninstallFiles(for: app, removeDataFolders: true)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            appPendingDelete = nil
            return
        }
        let id = LCDesktopIcon.appID(for: app)
        removeApp(app: app)
        desktopOrder.remove(id: id)
        desktopDock.removeEverywhere(id: id)
        refreshDock()
        appPendingDelete = nil
    }

    // MARK: - Desktop drag (custom long-press → drag, demo §1)

    /// The long-press → drag gesture for one icon (grid or Dock).
    /// Built here so the handlers can reach the order / Dock stores.
    /// Long-press fires `enterEditMode()`; the drag itself starts on
    /// the first move past the 7 pt threshold, so the same finger
    /// that long-pressed keeps dragging without lifting (demo §1.2).
    private func desktopIconDragGesture(for icon: LCDesktopIcon, isInDock: Bool) -> AnyGesture<SequenceGesture<LongPressGesture, DragGesture>.Value> {
        LCDesktopIconDragGesture(
            icon: icon,
            isInDock: isInDock,
            isEditing: isEditing,
            onLongPress: { _, _ in
                enterEditMode()
            },
            onDragChanged: { icon, isInDock, value in
                desktopIconDragChanged(icon: icon, isInDock: isInDock, value: value)
            },
            onDragEnded: { icon, isInDock, value in
                desktopIconDragEnded(icon: icon, isInDock: isInDock, value: value)
            }
        )
    }

    /// The Dock slot currently hovered as a drop target (swap), if any.
    /// An append target (empty Dock space) highlights the slot it will
    /// land in: the first empty slot, or the last slot when the Dock is
    /// full (that icon is the one the append evicts).
    private var dockDropTargetSlot: Int? {
        switch desktopDrag.dropTarget {
        case .dockSlot(let index, _):
            return index
        case .dockAppend:
            return min(dockDisplayIcons.count, LCDesktopDockStore.maxDockItems - 1)
        default:
            return nil
        }
    }

    /// Dock layer scale for the home-bar follow / switcher (demo
    /// §7.1 / §8.3). The Dock follows the front window down (scale
    /// 0.92 + p·0.08, opacity p) when a system page is open, and
    /// shrinks to 0.96 / 0.55 while the switcher is up.
    private var dockLayerScale: CGFloat {
        if showSwitcher { return 0.96 }
        if systemPage != nil { return 0.92 + homeBarState.followProgress * 0.08 }
        return 1.0
    }

    /// Dock layer opacity for the home-bar follow / switcher.
    private var dockLayerOpacity: Double {
        if showSwitcher { return 0.55 }
        if systemPage != nil { return Double(homeBarState.followProgress) }
        return 1.0
    }

    /// The ghost icon: the dragged tile (1.15× + shadow while
    /// dragging, shrinking to 1× on landing) at the finger's position
    /// in the "desktop" coordinate space, with its name label below
    /// for grid icons (mirroring the cell).
    private func desktopDragGhost(for icon: LCDesktopIcon) -> some View {
        let lift = max(0, min(1, (desktopDrag.ghostScale - 1) / 0.15))
        let tileSize: CGFloat = desktopDrag.draggedFromDock ? 56 : 60
        return VStack(spacing: 4) {
            LCDesktopIconTile(icon: icon, darkModeIcon: darkModeIcon, size: tileSize)
            if !desktopDrag.draggedFromDock {
                Text(icon.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(desktopTheme.nameColor)
                    .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1)
                    .frame(maxWidth: 76)
            }
        }
        .scaleEffect(desktopDrag.ghostScale)
        .shadow(color: .black.opacity(0.3 * lift), radius: 12 * lift, x: 0, y: 8 * lift)
        .position(x: desktopDrag.ghostCenter.x, y: desktopDrag.ghostCenter.y)
    }

    /// A drag move event: pick the icon up on the first move past the
    /// 7 pt threshold, then follow the finger, flip pages at the edges
    /// and update the drop target.
    private func desktopIconDragChanged(icon: LCDesktopIcon, isInDock: Bool, value: DragGesture.Value) {
        guard !desktopDrag.isLanding else { return }
        if !desktopDrag.isDragging {
            startDesktopDrag(icon: icon, isInDock: isInDock, value: value)
        }
        guard desktopDrag.isDragging else { return }
        updateDesktopDrag(value: value)
    }

    /// Picks the icon up: records the origin (cell centre + frame,
    /// finger location, grid/Dock origin) and shows the ghost.
    private func startDesktopDrag(icon: LCDesktopIcon, isInDock: Bool, value: DragGesture.Value) {
        let startFrame: CGRect
        let startCenter: CGPoint
        let originIndex: Int?
        if isInDock {
            let slot = dockDisplayIcons.firstIndex { $0.id == icon.id }
            if let slot, let frame = desktopDrag.dockSlotFrames[slot] {
                startFrame = frame
                startCenter = CGPoint(x: frame.midX, y: frame.midY)
            } else {
                // Frames not yet reported (first drag before the
                // preference change landed): centre the ghost on the
                // finger rather than offsetting it.
                startFrame = CGRect(
                    x: value.startLocation.x - 28,
                    y: value.startLocation.y - 28,
                    width: 56, height: 56
                )
                startCenter = value.startLocation
            }
            originIndex = nil
        } else {
            if let frame = desktopDrag.cellFrames[icon.id] {
                startFrame = frame
                startCenter = CGPoint(x: frame.midX, y: frame.midY)
            } else {
                startFrame = CGRect(
                    x: value.startLocation.x - 30,
                    y: value.startLocation.y - 39.5,
                    width: 60, height: 79
                )
                startCenter = value.startLocation
            }
            originIndex = desktopOrder.order.firstIndex(of: icon.id)
        }
        desktopDrag.beginDrag(
            icon: icon,
            fromDock: isInDock,
            originIndex: originIndex,
            startCenter: startCenter,
            startFrame: startFrame,
            startLocation: value.startLocation
        )
    }

    /// Follows the finger: ghost position, edge page-flip, drop target.
    private func updateDesktopDrag(value: DragGesture.Value) {
        let location = value.location
        desktopDrag.ghostCenter = CGPoint(
            x: desktopDrag.dragStartCenter.x + (location.x - desktopDrag.dragStartLocation.x),
            y: desktopDrag.dragStartCenter.y + (location.y - desktopDrag.dragStartLocation.y)
        )
        // Edge page-flip (demo §1.6): a 24 pt zone at each screen
        // edge, 650 ms cooldown, and the first flip needs 650 ms of
        // dragging first (lastFlip is set at drag start). The hover
        // clears on flip; the frames refresh after the page lands.
        let now = CACurrentMediaTime()
        let width = UIScreen.main.bounds.width
        if now - desktopDrag.lastFlipTime >= LCDesktopDragState.edgeFlipCooldown {
            if location.x > width - LCDesktopDragState.edgeFlipZoneWidth, currentPage < desktopPageCount - 1 {
                desktopDrag.lastFlipTime = now
                flipPage(.next)
                desktopDrag.setDropTarget(.none)
                return
            }
            if location.x < LCDesktopDragState.edgeFlipZoneWidth, currentPage > 0 {
                desktopDrag.lastFlipTime = now
                flipPage(.previous)
                desktopDrag.setDropTarget(.none)
                return
            }
        }
        desktopDrag.setDropTarget(hitTestDropTarget(at: location))
    }

    /// Hit-tests the finger against the live frames: the Dock first
    /// (slot or empty space), then the current page's cells, then the
    /// page's blank area. Anything else is an invalid spot.
    private func hitTestDropTarget(at point: CGPoint) -> LCDesktopDropTarget {
        if desktopDrag.dockFrame.contains(point) {
            for (slot, frame) in desktopDrag.dockSlotFrames where frame.contains(point) {
                if slot < dockDisplayIcons.count {
                    return .dockSlot(index: slot, iconID: dockDisplayIcons[slot].id)
                }
                return .dockAppend
            }
            return .dockAppend
        }
        let icons = currentPage < desktopPages.count ? desktopPages[currentPage] : []
        for icon in icons {
            if let frame = desktopDrag.cellFrames[icon.id], frame.contains(point) {
                return .cell(id: icon.id)
            }
        }
        if let gridFrame = desktopDrag.gridFrames[currentPage], gridFrame.contains(point) {
            return .pageEnd(page: currentPage)
        }
        return .none
    }

    /// Release: the ghost flies to its landing cell (0.42 s,
    /// no-overshoot) or back to its origin cell (0.45 s), and the
    /// order commits at handoff (demo §1.7).
    private func desktopIconDragEnded(icon: LCDesktopIcon, isInDock: Bool, value: DragGesture.Value) {
        guard desktopDrag.isDragging, !desktopDrag.isLanding else { return }
        guard let draggedID = desktopDrag.draggedID else { return }
        let target = desktopDrag.dropTarget
        let fromDock = desktopDrag.draggedFromDock
        let originIndex = desktopDrag.dragOriginIndex
        let (changes, targetCenter) = landingPlan(draggedID: draggedID, target: target, fromDock: fromDock)
        let duration = changes ? LCDesktopDragState.landingDuration : LCDesktopDragState.flyBackDuration
        desktopDrag.beginLanding()
        withAnimation(.spring(response: duration, dampingFraction: 1.0)) {
            desktopDrag.ghostCenter = targetCenter
            desktopDrag.ghostScale = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.03) { [draggedID, target, fromDock, originIndex] in
            if changes {
                self.commitDrop(draggedID: draggedID, target: target, fromDock: fromDock, originIndex: originIndex)
            }
            desktopDrag.finishLanding()
        }
    }

    /// Resolves the landing: whether the drop changes anything, and
    /// where the ghost flies to (the target cell's centre, or the
    /// origin cell for a no-change drop).
    private func landingPlan(draggedID: String, target: LCDesktopDropTarget, fromDock: Bool) -> (changes: Bool, center: CGPoint) {
        let originCenter = CGPoint(x: desktopDrag.dragStartFrame.midX, y: desktopDrag.dragStartFrame.midY)
        switch target {
        case .cell(let targetID):
            guard targetID != draggedID else { return (false, originCenter) }
            if let frame = desktopDrag.cellFrames[targetID] {
                return (true, CGPoint(x: frame.midX, y: frame.midY))
            }
            return (true, originCenter)
        case .dockSlot(let index, let iconID):
            guard iconID != draggedID, !fromDock, !LCDesktopIcon.isSystemID(draggedID) else { return (false, originCenter) }
            if let frame = desktopDrag.dockSlotFrames[index] {
                return (true, CGPoint(x: frame.midX, y: frame.midY))
            }
            return (true, originCenter)
        case .dockAppend:
            guard !fromDock, !LCDesktopIcon.isSystemID(draggedID) else { return (false, originCenter) }
            let appendIndex = min(dockDisplayIcons.count, LCDesktopDockStore.maxDockItems - 1)
            if let frame = desktopDrag.dockSlotFrames[appendIndex] {
                return (true, CGPoint(x: frame.midX, y: frame.midY))
            }
            return (true, CGPoint(x: desktopDrag.dockFrame.midX, y: desktopDrag.dockFrame.midY))
        case .pageEnd(let page):
            let icons = page < desktopPages.count ? desktopPages[page] : []
            if icons.last?.id == draggedID { return (false, originCenter) }
            if let lastID = icons.last?.id, let frame = desktopDrag.cellFrames[lastID] {
                // The icon lands in the next slot after the last one:
                // one column to the right, or the first column of the
                // next row if the row is full. The column width is the
                // cell width + the 12 pt column spacing; the row
                // height is the cell height + the 18 pt row spacing.
                let col = (icons.count - 1) % 4
                let cellW = frame.width
                let cellH = frame.height
                if col < 3 {
                    return (true, CGPoint(x: frame.midX + cellW + 12, y: frame.midY))
                }
                let firstColX = frame.midX - CGFloat(col) * (cellW + 12)
                return (true, CGPoint(x: firstColX, y: frame.midY + cellH + 18))
            }
            // Empty page: the first slot's position.
            if let gridFrame = desktopDrag.gridFrames[page] {
                let cellSize = desktopDrag.dragStartFrame.size
                let center = CGPoint(
                    x: gridFrame.minX + 20 + cellSize.width / 2,
                    y: gridFrame.minY + 12 + cellSize.height / 2
                )
                return (true, center)
            }
            return (true, originCenter)
        case .none:
            return (false, originCenter)
        }
    }

    /// Commits a drop at handoff (demo §1.5 swap semantics). Called
    /// after the ghost's landing flight, inside the landing spring's
    /// animation so the swapped icons glide to their new slots.
    private func commitDrop(draggedID: String, target: LCDesktopDropTarget, fromDock: Bool, originIndex: Int?) {
        let spring = Animation.spring(response: LCDesktopDragState.landingDuration, dampingFraction: 1.0)
        switch target {
        case .cell(let targetID):
            guard targetID != draggedID else { return }
            if fromDock {
                // Dock → occupied grid cell: the occupant goes to
                // the first free slot, the dragged icon takes the cell.
                withAnimation(spring) {
                    desktopDock.removeFromDock(id: draggedID)
                    desktopOrder.replace(id: targetID, with: draggedID)
                    desktopOrder.insert(id: targetID, at: desktopOrder.order.count)
                }
            } else {
                withAnimation(spring) {
                    desktopOrder.swap(id: draggedID, withID: targetID)
                }
            }
        case .dockSlot(let index, let iconID):
            guard iconID != draggedID, !fromDock, !LCDesktopIcon.isSystemID(draggedID) else { return }
            // Grid → occupied Dock slot: swap. The Dock icon returns
            // to the dragged icon's original grid cell.
            withAnimation(spring) {
                desktopOrder.remove(id: draggedID)
                desktopDock.replaceDockIcon(at: index, with: draggedID)
                if let originIndex, originIndex <= desktopOrder.order.count {
                    desktopOrder.insert(id: iconID, at: originIndex)
                } else {
                    desktopOrder.insert(id: iconID, at: desktopOrder.order.count)
                }
            }
        case .dockAppend:
            guard !fromDock, !LCDesktopIcon.isSystemID(draggedID) else { return }
            dropIconOnDock(draggedID)
        case .pageEnd(let page):
            moveIconToPageEnd(draggedID: draggedID, page: page)
        case .none:
            break
        }
    }

    /// Drop on a page's blank area: land at the end of that page.
    func moveIconToPageEnd(draggedID: String, page: Int) {
        // Landing spring (demo §1.7): 0.42 s, no overshoot.
        withAnimation(.spring(response: 0.42, dampingFraction: 1.0)) {
            if desktopDock.dockIDs.contains(draggedID) {
                desktopDock.removeFromDock(id: draggedID)
            }
            let pageIcons = page < desktopPages.count ? desktopPages[page] : []
            if let lastID = pageIcons.last?.id, let lastIndex = desktopOrder.order.firstIndex(of: lastID) {
                desktopOrder.insert(id: draggedID, at: lastIndex + 1)
            } else {
                desktopOrder.insert(id: draggedID, at: desktopOrder.order.count)
            }
        }
    }

    /// Drop an icon onto the Dock. If the Dock is full, the last Dock
    /// icon is evicted back to the grid (never lost, never deleted).
    func dropIconOnDock(_ draggedID: String) {
        // System icons never enter the Dock: they live in the grid.
        guard !draggedID.isEmpty, !desktopDock.dockIDs.contains(draggedID),
              !LCDesktopIcon.isSystemID(draggedID) else {
            return
        }
        // Landing spring (demo §1.7): 0.42 s, no overshoot.
        withAnimation(.spring(response: 0.42, dampingFraction: 1.0)) {
            let evicted = desktopDock.addToDock(id: draggedID)
            desktopOrder.remove(id: draggedID)
            if let evicted {
                desktopOrder.insert(id: evicted, at: desktopOrder.order.count)
            }
        }
    }

    /// Dock "−": remove the icon from the Dock only; it returns to the
    /// grid (at the end). The app itself is NOT deleted.
    func removeIconFromDock(_ icon: LCDesktopIcon) {
        desktopDock.removeFromDock(id: icon.id)
        desktopOrder.insert(id: icon.id, at: desktopOrder.order.count)
    }
    func removeApp(app: LCAppModel) {
        DispatchQueue.main.async {
            sharedModel.apps.removeAll { now in
                return app == now
            }
            sharedModel.hiddenApps.removeAll { now in
                return app == now
            }
            
        }
    }
    
    func changeAppVisibility(app: LCAppModel) {
        DispatchQueue.main.async {
            if app.appInfo.isHidden {
                sharedModel.apps.removeAll { now in
                    return app == now
                }
                if !sharedModel.hiddenApps.contains(app) {
                    sharedModel.hiddenApps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .removeObjects(in: app.appInfo.urlSchemes() as! [Any])
            } else {
                sharedModel.hiddenApps.removeAll { now in
                    return app == now
                }
                if !sharedModel.apps.contains(app) {
                    sharedModel.apps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .addObjects(from: app.appInfo.urlSchemes() as! [Any])
            }
            
        }
    }
    
    func launchAppWithBundleId(bundleId : String, container : String?, urlStr: String? = nil, forceJIT: Bool? = nil) async {
        if bundleId == "" {
            return
        }
        var appFound : LCAppModel? = nil
        var isFoundAppLocked = false
        for app in sharedModel.apps {
            if app.appInfo.relativeBundlePath == bundleId {
                appFound = app
                if app.appInfo.isLocked {
                    isFoundAppLocked = true
                }
                break
            }
        }
        if appFound == nil && !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
            for app in sharedModel.hiddenApps {
                if app.appInfo.relativeBundlePath == bundleId {
                    appFound = app
                    isFoundAppLocked = true
                    break
                }
            }
        }
        
        if appFound == nil && bundleId == "builtinSideStore" {
            appFound = LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared)
        }
        
        if isFoundAppLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        
        guard let appFound else {
            errorInfo = "lc.appList.appNotFoundError".loc
            errorShow = true
            return
        }

        LCDesktopLaunchCountStore.recordLaunch(id: LCDesktopIcon.appID(for: appFound))
        if #available(iOS 16.2, *) {
            LCContainerLiveActivityManager.startLaunching(appName: appFound.displayName)
        }
        do {
            try await appFound.runApp(multitask: nil, containerFolderName: container, urlStr: urlStr, forceJIT: forceJIT)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        if #available(iOS 16.2, *) {
            LCContainerLiveActivityManager.finish(statusText: "lc.common.done".loc)
        }
        
    }
    
    func authenticateUser() async {
        do {
            if !(try await LCUtils.authenticateUser()) {
                return
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }
    
    func jitLaunch(appName: String, classicMode: UInt) async {
        await jitLaunch(withScript: "", appName: appName, classicMode: classicMode)
    }

    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {
        await MainActor.run {
            jitLog = ""
        }
        let enableJITTask = Task {
            
            let _ = await LCUtils.askForJIT(withScript: script, appName: appName, classicMode: classicMode) { newMsg in
                Task { await MainActor.run {
                    self.jitLog += "\(newMsg)\n"
                }}
            }
            guard let _ = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) else {
                return
            }
        }
        guard let result = await jitAlert.open(), result else {
            UserDefaults.standard.removeObject(forKey: "selected")
            enableJITTask.cancel()
            return
        }
        LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)

    }
    
    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                
            
            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {
                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                    let encoded = encodedData.map { "&script=\($0)" } ?? ""
                    if jitEnabler == .StosDebugLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stosdebug") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&relaunchApp=false& forcePID=true\(encoded)") {
                                Task { await openWebView(urlString: url.absoluteString) }
                            }
                        } else {
                            errorInfo = "StosDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&forcePID=true\(encoded)") {
                            UIApplication.shared.open(url)
                        }
                    }
                    return
                }
                
                let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
                if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                    if jitEnabler == .StikJITLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stikjit") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            Task { await openWebView(urlString: url.absoluteString) }
                        } else {
                            errorInfo = "StikDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    func showRunWhenMultitaskAlert() async -> Bool? {
        return await runWhenMultitaskAlert.open()
    }
    
    func installMdm(data: Data) {
        safariViewURL = URL(string:"data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())")!
        safariViewOpened = true
    }
    
    func openNavigationView(view: AnyView) {
        navigateTo = view
        isNavigationActive = true
    }
    
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle? {
        if #available(iOS 18.0, *) {
            return await generatedIconStyleSelector.open()
        } else {
            return .Light
        }
        
    }
    
    func closeNavigationView() {
        isNavigationActive = false
        navigateTo = nil
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func handleURL(url : URL) {
        if url.isFileURL {
            Task { await installFromUrl(urlStr: url.absoluteString) }
            return
        }
        
        if url.scheme == "sidestore" && UserDefaults.sideStoreExist() {
            UserDefaults.standard.setValue(url.absoluteString, forKey: "launchAppUrlScheme")
            LCUtils.openSideStore(delegate: self)
            return
        }
        
        if url.host == "open-web-page" || url.host == "open-url" {
            if let urlComponent = URLComponents(url: url, resolvingAgainstBaseURL: false), let queryItem = urlComponent.queryItems?.first {
                if queryItem.value?.isEmpty ?? true {
                    return
                }
                
                if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                   let decodedUrl = String(data: decodedData, encoding: .utf8) {
                    Task { await openWebView(urlString: decodedUrl) }
                }
            }
        } else if url.host == "sealbox-launch" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var bundleId : String? = nil
                var containerName : String? = nil
                var forceJIT: Bool? = nil
                var urlStr: String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "bundle-name", let bundleId1 = queryItem.value {
                        bundleId = bundleId1
                    } else if queryItem.name == "container-folder-name", let containerName1 = queryItem.value {
                        containerName = containerName1
                    } else if queryItem.name == "jit", let forceJIT1 = queryItem.value {
                        if forceJIT1 == "true" {
                            forceJIT = true
                        } else if forceJIT1 == "false" {
                            forceJIT = false
                        }
                    } else if queryItem.name == "open-url" {
                        if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                           let decodedUrl = String(data: decodedData, encoding: .utf8) {
                            urlStr = decodedUrl
                        }
                    }
                }
                if let bundleId, bundleId != "ui"{
                    Task { await launchAppWithBundleId(bundleId: bundleId, container: containerName, urlStr: urlStr, forceJIT: forceJIT) }
                }
            }
        } else if url.host == "install" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var installUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        installUrl = installUrl1
                    }
                }
                if let installUrl {
                    Task { await installFromUrl(urlStr: installUrl) }
                }
            }
        }
    }
    
}

extension View {
    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V { block(self) }
}
