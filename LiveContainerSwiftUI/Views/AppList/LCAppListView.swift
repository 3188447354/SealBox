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
    /// (0.5 s). Exited by tapping blank desktop or the "···" menu's
    /// Done entry. There is no toolbar "✓" anymore: the home screen
    /// has no toolbar at all.
    @State private var isEditing = false
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
        GeometryReader { geometry in
        ZStack {
            // Wallpaper fills the whole phone screen, behind everything
            // including the Dock area (the Dock is translucent).
            desktopBackgroundView

            VStack(spacing: 0) {
                // Top strip: edit-mode capsules, the floating search
                // field, the install progress pill. Empty in normal
                // mode — the desktop shows nothing but icons.
                if isEditing {
                    editModeTopBar
                }
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
            .overlay(alignment: .leading) {
                edgeZone(direction: .previous)
            }
            .overlay(alignment: .trailing) {
                edgeZone(direction: .next)
            }
            // Tap the blank desktop to exit edit mode; triple-tap it
            // in normal mode to unlock hidden apps (the unlock gesture
            // used to live behind the old app-counter footer, which is
            // gone with the old list UI).
            .onTapGesture {
                if isEditing {
                    exitEditMode()
                }
            }
            .onTapGesture(count: 3) {
                if !isEditing {
                    Task { await authenticateUser() }
                }
            }
            // Long-press the blank desktop to enter edit mode. This
            // gesture did not exist before: long-pressing blank space
            // did literally nothing (only icons had a long-press), and
            // long-pressing an icon was eaten by its onDrag (see the
            // drag gating in desktopPageGrid), so on a real device
            // long-press never entered edit mode at all.
            .onLongPressGesture(minimumDuration: 0.5) {
                if !isEditing {
                    isEditing = true
                }
            }
        }
        // SealBox shell (§11 / §13): the whole desktop window shrinks
        // with the home-bar gesture (scaleEffect on the desktop content
        // only — the trigger and lock button below are overlays attached
        // after it, so they stay put and keep receiving gestures).
        // The frame pins the overlay anchors to the full content area
        // above the Dock.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(homeBarState.windowScale)
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
            }
        }
        }
        .coordinateSpace(name: "scroll")
        .onAppear {
            if !didAppear {
                onAppear()
            }
        }
        .onAppear {
            // Wire the edge auto-flip action and bring the persisted
            // order / Dock up to date with the installed apps.
            desktopDrag.flipPageAction = { [weak desktopDrag] direction in
                guard desktopDrag != nil else {
                    return
                }
                flipPage(direction)
            }
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
                showSwitcher = false
                systemPage = nil
            case .openSwitcher:
                // Refresh from the real open-window registries first,
                // then show. The system-page cover (if any) must go
                // away too: the switcher is an overlay on the desktop,
                // so it would stay hidden behind the cover otherwise.
                switcherStore.refresh(
                    apps: sharedModel.apps + sharedModel.hiddenApps,
                    tweakNames: sharedModel.tweakFolderNames,
                    openSystemPage: systemPage,
                    darkModeIcon: darkModeIcon
                )
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
                onTapIcon: { icon in
                    desktopIconTapped(icon)
                },
                onDeleteIcon: { icon in
                    // Dock "−" removes the icon from the Dock only
                    // (it returns to the grid). It never deletes the
                    // app; app deletion is the grid "−" button.
                    removeIconFromDock(icon)
                },
                onLongPressIcon: {
                    if !isEditing {
                        isEditing = true
                    }
                },
                onDragStarted: { icon in
                    desktopDrag.beginDrag(id: icon.id)
                },
                onDragEntered: {
                    desktopDrag.isOverDock = true
                },
                onDragExited: {
                    desktopDrag.isOverDock = false
                },
                onDropOnDock: { draggedID in
                    dropIconOnDock(draggedID)
                }
            )
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
            // edge and travels right more than 80pt (and more
            // horizontally than vertically) dismisses the page.
            // simultaneousGesture so the page's own vertical scrolling
            // keeps working; a drag starting anywhere else, or a
            // mostly-vertical drag, never dismisses. The gesture lives
            // only on this cover, so a right swipe on the desktop's
            // first page can never trigger it, and it is unrelated to
            // the desktop's edit-mode icon dragging.
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
                            if value.translation.width > 80
                                && abs(value.translation.height) < value.translation.width {
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
            }
        }
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
            }
        }

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
    var desktopPageCount: Int {
        max(1, desktopPages.count)
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
                    .overlay(desktopTheme.wallpaperDim)
                    .clipped()
                    .ignoresSafeArea()
            }
        }
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
                    isDropTarget: desktopDrag.dropTargetID == icon.id,
                    darkModeIcon: darkModeIcon,
                    theme: desktopTheme,
                    onTap: {
                        desktopIconTapped(icon)
                    },
                    onDelete: icon.isDeletable ? {
                        requestDelete(icon)
                    } : nil,
                    onLongPress: {
                        if !isEditing {
                            isEditing = true
                        }
                    }
                )
                .apply { cell in
                    // Dragging is disabled while searching: a search
                    // shows a filtered subset, and reordering a subset
                    // would corrupt the persisted full order.
                    // Dragging is ALSO disabled while NOT in edit mode.
                    // That is the long-press fix: SwiftUI's onDrag
                    // carries its own internal press recogniser, and it
                    // claims the touch before the cell's 0.5 s
                    // long-press can fire — so on a real device a
                    // long-press on an icon never entered edit mode, it
                    // just silently armed a drag. With onDrag gated off
                    // outside edit mode, the long-press is the only
                    // press gesture and it fires; once editing, onDrag
                    // attaches and dragging works. (Same touch cannot
                    // continue from "enter edit" into a drag — the drag
                    // gesture attaches mid-touch and misses this touch;
                    // lift the finger and long-press again to drag, the
                    // same as the iPhone home screen's second press.)
                    if isSearching || !isEditing {
                        cell
                    } else {
                        cell
                            .onDrag {
                                desktopDrag.beginDrag(id: icon.id)
                                return NSItemProvider(object: NSString(string: icon.id))
                            }
                            .onDrop(
                                of: [.text],
                                delegate: LCDesktopCellDropDelegate(
                                    targetID: icon.id,
                                    dragState: desktopDrag,
                                    onMove: moveIcon
                                )
                            )
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Drop on the page's blank area: land at the end of this page.
        // This also allows dropping onto the last page's blank area.
        .onDrop(
            of: [.text],
            delegate: LCDesktopPageDropDelegate(
                page: page,
                dragState: desktopDrag,
                onMoveToPageEnd: moveIconToPageEnd
            )
        )
    }

    /// Custom page dots (not the system PageTabViewStyle dots: the system
    /// dots' style and position cannot be guaranteed to sit above the
    /// Dock, and they are not tappable). Centred above the Dock; current
    /// page is a bright solid dot, others gray; tappable to jump; hidden
    /// when there is only one page.
    private var desktopPageDots: some View {
        Group {
            if desktopPageCount > 1 {
                HStack(spacing: 8) {
                    ForEach(0..<desktopPageCount, id: \.self) { page in
                        Button {
                            withAnimation {
                                currentPage = page
                            }
                        } label: {
                            Circle()
                                .fill(page == currentPage ? Color.primary : Color.secondary.opacity(0.5))
                                .frame(width: 8, height: 8)
                        }
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

    /// Exits edit mode: stops jiggling and dragging, hides the search
    /// field and clears the query.
    private func exitEditMode() {
        isEditing = false
        desktopDrag.endDrag()
        showSearchBar = false
        searchContext.query = ""
    }

    /// Invisible 28pt edge zone, only present while a drag is active.
    /// Hovering flips one page after 0.7 s and re-arms while hovering.
    private func edgeZone(direction: LCDesktopEdgeDirection) -> some View {
        Group {
            if desktopDrag.isDragging {
                Color.clear
                    .frame(width: 28)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [.text],
                        delegate: LCDesktopEdgeDropDelegate(
                            direction: direction,
                            dragState: desktopDrag
                        )
                    )
            }
        }
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
        // Explicit spring (was withAnimation with the default curve):
        // the page glides instead of snapping when an edge hover
        // flips it mid-drag.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
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

    /// Move the dragged icon to just before `targetID`. A Dock icon
    /// dragged onto the grid leaves the Dock (its slot stays empty).
    func moveIcon(draggedID: String, toBeforeID targetID: String) {
        // Spring the reorder instead of snapping: the icons glide to
        // their new slots on drop (see the drag-smoothness notes in
        // SEALBOX_DOCK_FIX.md). The drop itself still only happens on
        // performDrop — the hover state only shows the dashed slot.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if desktopDock.dockIDs.contains(draggedID) {
                desktopDock.removeFromDock(id: draggedID)
            }
            desktopOrder.move(id: draggedID, beforeID: targetID)
        }
        desktopDrag.endDrag()
    }

    /// Drop on a page's blank area: land at the end of that page.
    func moveIconToPageEnd(draggedID: String, page: Int) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
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
        desktopDrag.endDrag()
    }

    /// Drop an icon onto the Dock. If the Dock is full, the last Dock
    /// icon is evicted back to the grid (never lost, never deleted).
    func dropIconOnDock(_ draggedID: String) {
        // System icons never enter the Dock: they live in the grid.
        guard !draggedID.isEmpty, !desktopDock.dockIDs.contains(draggedID),
              !LCDesktopIcon.isSystemID(draggedID) else {
            desktopDrag.endDrag()
            return
        }
        // Same spring as the grid drops: the Dock fills and the
        // evicted icon glides back to the grid instead of jumping.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            let evicted = desktopDock.addToDock(id: draggedID)
            desktopOrder.remove(id: draggedID)
            if let evicted {
                desktopOrder.insert(id: evicted, at: desktopOrder.order.count)
            }
        }
        desktopDrag.endDrag()
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
