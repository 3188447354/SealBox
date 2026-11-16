//
//  DesktopView.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — desktop assembly.
//
//  Opens as a full-screen wallpaper + 4-column icon grid + Dock: no
//  title, no search bar, no toolbar, no Tab Bar (research §5). Empty
//  desktop is just the wallpaper — zero copy. Pages: TabView(.page),
//  24 icons per page (4 × 6, Dock excluded), system page dots drawn by
//  hand (tappable, hidden on a single page), page spring 0.52 / 0.75,
//  wallpaper parallax −12pt per page (0.55 s spring).
//
//  Blank-area gestures live on each page's background layer (a sibling
//  behind the grid, NOT on an ancestor): a tap on an icon never reaches
//  them, a tap on empty space exits edit mode (400 ms guard) and a
//  0.45 s long-press enters it. Normal-mode icon drag is
//  hold-through (item 7): a sequenced LongPress -> Drag gesture
//  lifts the icon, drags it, or opens the custom menu on release
//  without a drag — the old system contextMenu is gone because it
//  owned the long-press touch and made that impossible.

import Foundation
import SwiftUI

struct DesktopView: View {
    @EnvironmentObject var sharedModel: SharedModel
    @Environment(\.scenePhase) var scenePhase

    @StateObject private var orderStore = LCDesktopOrderStore()
    @StateObject private var dockStore = LCDesktopDockStore()
    @StateObject private var metaStore = LCDesktopMetaStore()
    @StateObject private var dragState = LCDesktopDragState()
    @StateObject private var editState = DesktopEditState()
    @StateObject private var zoomState = LaunchZoomState()
    @StateObject private var installFlow = InstallFlow.shared
    @StateObject private var nudgeState = NotificationCenterNudgeState()

    @State private var currentPage = 0
    @State private var showPicker = false
    @State private var showCertSheet = false
    @State private var showSearch = false
    @State private var showControlCenter = false
    @State private var jitEnabledForControlCenter = false
    @State private var showSwitcher = false
    @State private var switcherApps: [LCAppModel] = []
    @State private var coachMarkDismissed = EmptyStateCoachMarkStore.shownBefore
    @State private var detailApp: LCAppModel?
    @State private var showDetail = false
    @State private var renameApp: LCAppModel?
    @State private var showRename = false
    @State private var appPendingDelete: LCAppModel?
    @State private var showDeleteConfirm = false
    @State private var alertMessage: String?
    @State private var zoomIconImage: UIImage?
    /// Icon currently lifted by a normal-mode long-press (item 7):
    /// it scales up in place until the finger moves (drag) or lifts
    /// (menu). Set on long-press success, cleared on drag start or
    /// on touch-up.
    @State private var liftedID: String?
    /// Long-press succeeded but the finger has not dragged yet: if
    /// it lifts now, the menu opens for this icon.
    @State private var menuCandidateID: String?
    /// The custom long-press menu (item 7), anchored at the icon.
    @State private var menuRequest: DesktopMenuRequest?

    private enum DragOrigin {
        case grid(slot: Int)
        case dock(slot: Int)
    }
    @State private var dragOrigin: DragOrigin?

    static let iconsPerPage = 24

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
    }

    // MARK: - Derived

    /// Visible apps: hidden apps stay out until the triple-tap unlock.
    private var visibleApps: [LCAppModel] {
        sharedModel.apps.filter { !$0.uiIsHidden || editState.hiddenUnlocked }
    }

    private var modelByID: [String: LCAppModel] {
        Dictionary(uniqueKeysWithValues: sharedModel.apps.map { (LCDesktopIcon.appID(for: $0), $0) })
    }

    private var visibleIDs: [String] {
        visibleApps.map { LCDesktopIcon.appID(for: $0) }
    }

    private var dockIcons: [LCDesktopIcon] {
        dockStore.dockIDs.compactMap { modelByID[$0] }.map { LCDesktopIcon.app($0) }
    }

    /// Search rows: display name (rename overrides included) + Bundle ID.
    private var searchableApps: [SearchableApp] {
        visibleApps.map { model in
            let id = LCDesktopIcon.appID(for: model)
            return SearchableApp(
                id: id,
                displayName: metaStore.displayName(for: id, fallback: model.displayName),
                bundleID: model.bundleIdentifier,
                model: model
            )
        }
    }

    /// The one-time empty-desktop coach mark: only when the desktop is
    /// empty, edit mode was just entered, and it has never been shown.
    private var showCoachMark: Bool {
        sharedModel.apps.isEmpty && editState.isEditing && !coachMarkDismissed
    }

    /// Open the switcher with a snapshot of the apps running right now
    /// (LCAppModel.isAppRunning). Multitask is frozen in v1, so this is
    /// normally empty — and an empty switcher says so instead of
    /// inventing cards.
    private func openSwitcher() {
        // 0.0.4: the switcher lists the windows that are actually
        // running. isAppRunning is only true while a launch is in
        // flight (runApp clears it in defer), so the old filter
        // showed an empty switcher as soon as the launch finished.
        // Multitask windows live in MultitaskDockManager.apps —
        // registered by MultitaskAppWindow onAppInitialize when the
        // scene opens, removed when it terminates — so map each
        // registered window back to its model by container folderName
        // (DockAppModel.appUUID), in registry (launch) order. Hidden
        // apps are included: a running hidden app still needs a way
        // back. Tapping a card still goes through launchDesktopApp
        // -> runApp, which brings an already-running multitask
        // window to front instead of relaunching.
        // iOS 15 has no registry (MultitaskDockManager is iOS 16+):
        // keep the old filter there.
        if #available(iOS 16.0, *) {
            let running = MultitaskDockManager.shared.apps
            if !running.isEmpty {
                var seen = Set<ObjectIdentifier>()
                switcherApps = running.compactMap { dockApp in
                    guard let model = (sharedModel.apps + sharedModel.hiddenApps).first(where: {
                        $0.appInfo.containers.contains { $0.folderName == dockApp.appUUID }
                    }) else { return nil as LCAppModel? }
                    guard seen.insert(ObjectIdentifier(model)).inserted else { return nil as LCAppModel? }
                    return model
                }
                showSwitcher = true
                return
            }
        }
        switcherApps = sharedModel.apps.filter { $0.isAppRunning }
        showSwitcher = true
    }

    /// Pull-down zones (research §1.6/§1.7): the top edge belongs to
    /// control center (right corner) and notification centre (left /
    /// centre); the middle of the screen belongs to search. Only in
    /// normal mode — never while editing, searching, or in a panel.
    ///
    /// 0.0.7: this used to fire on ANY downward drag, including a
    /// long-press icon drag — it never excluded an in-progress drag
    /// and its 60pt threshold was easy to cross by accident, so
    /// search kept popping up mid-drag. Now: no trigger while an
    /// icon is lifted or being dragged, a 120pt pull, and the drag
    /// must start on empty space — never on an icon cell or a Dock
    /// slot (frames and this gesture's locations share the
    /// "desktop" coordinate space).
    private func pullDownGesture() -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !editState.isEditing, !showSearch, !showControlCenter, !showSwitcher, menuRequest == nil,
                      dragState.draggedID == nil, liftedID == nil else { return }
                let start = value.startLocation
                let dy = value.translation.height
                guard dy > 120, abs(value.translation.width) < 60 else { return }
                guard dragState.iconID(at: start) == nil,
                      dragState.dockSlotIndex(at: start) == nil else { return }
                let width = UIScreen.main.bounds.width
                if start.y < 80 {
                    if start.x > width - 140 {
                        jitEnabledForControlCenter = isJITEnabledNow()
                        withAnimation(.spring(response: 0.58, dampingFraction: 0.8)) {
                            showControlCenter = true
                        }
                    } else {
                        // Notification centre is not in v1: bounce +
                        // first-time toast, never a fake notification.
                        nudgeState.nudge()
                    }
                } else if start.y > 120 {
                    showSearch = true
                }
            }
    }

    private var pageCount: Int {
        let last = orderStore.order.lastIndex(where: { !$0.isEmpty }) ?? -1
        return max(1, last / Self.iconsPerPage + 1)
    }

    /// Slot ids for one page ("" = empty slot).
    private func pageSlotIDs(_ page: Int) -> [String] {
        (0..<Self.iconsPerPage).map { cell in
            let slot = page * Self.iconsPerPage + cell
            return orderStore.order.indices.contains(slot) ? orderStore.order[slot] : ""
        }
    }

    // MARK: - Sync

    private func syncDesktopOrder() {
        let dockIDs = Set(dockStore.dockIDs)
        // 0.0.5: the fixed Settings entry lives in the order at slot 0
        // (first page, first cell). It is in allIDs so sync() never
        // frees it; pinSystemIconFirst puts it at the front on the
        // first sync after the upgrade (sync alone would append it at
        // the end). It never enters the Dock (dockIDs are app ids
        // only) or search (searchableApps is built from visibleApps).
        orderStore.sync(allIDs: [LCSystemPage.settings.id] + visibleIDs.filter { !dockIDs.contains($0) })
        orderStore.pinSystemIconFirst(id: LCSystemPage.settings.id)
        dockStore.seedIfNeeded(launchCounts: metaStore.launchCounts, allIDs: visibleIDs)
        if currentPage >= pageCount {
            currentPage = max(0, pageCount - 1)
        }
    }

    private func flipPage(_ direction: DesktopEdgeDirection) {
        withAnimation(.spring(response: 0.52, dampingFraction: 0.75)) {
            switch direction {
            case .previous:
                currentPage = max(0, currentPage - 1)
            case .next:
                currentPage = min(pageCount - 1, currentPage + 1)
            }
        }
    }

    // MARK: - Launch

    private func iconCenter(for icon: LCDesktopIcon) -> CGPoint? {
        if let frame = dragState.cellFrames[icon.id] {
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        if let slot = dockIcons.firstIndex(where: { $0.id == icon.id }),
           let frame = dragState.dockSlotFrames[slot] {
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        return nil
    }

    private func launchDesktopApp(_ app: LCAppModel, zoomFrom icon: LCDesktopIcon? = nil) {
        // Certificate gate first — before any animation.
        guard hasImportedCertificate else {
            showCertSheet = true
            return
        }
        Task {
            if app.appInfo.isLocked {
                do {
                    guard try await LCUtils.authenticateUser() else { return }
                } catch {
                    await MainActor.run { alertMessage = error.localizedDescription }
                    return
                }
            }
            // Icon-zoom opening (460 ms wait), then runApp.
            if let icon, let origin = iconCenter(for: icon) {
                let screen = UIScreen.main.bounds
                let zoomIcon = icon.appModel?.appInfo.iconIsDarkIcon(false)
                await MainActor.run {
                    zoomIconImage = zoomIcon
                    zoomState.start(from: UnitPoint(x: origin.x / screen.width, y: origin.y / screen.height))
                    zoomState.expand()
                }
                try? await Task.sleep(nanoseconds: LaunchZoomState.zoomWaitNanoseconds)
            }
            metaStore.recordLaunch(id: LCDesktopIcon.appID(for: app))
            // 0.0.6 watchdog: runApp's await can hang forever if the
            // launch callback never arrives (0.0.5 did exactly that —
            // the zoom froze and no error ever showed). If the app is
            // still launching after the timeout, pull the zoom down and
            // report instead of freezing on the enlarged icon. 30 s is
            // generous: ZSign re-signing + scene init on device take a
            // few seconds even for large apps.
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: LaunchZoomState.launchTimeoutNanoseconds)
                await MainActor.run {
                    guard app.isAppRunning else { return }
                    if zoomState.isActive {
                        zoomState.end()
                        zoomIconImage = nil
                    }
                    alertMessage = "启动超时，请重试"
                }
            }
            do {
                try await app.runApp()
            } catch {
                if isMissingCertificateError(error) {
                    await MainActor.run { showCertSheet = true }
                } else {
                    await MainActor.run { alertMessage = error.localizedDescription }
                }
            }
            watchdog.cancel()
            await MainActor.run {
                zoomState.end()
                zoomIconImage = nil
            }
        }
    }

    private func launchAppWithBundleId(_ launch: PendingDeepLinkLaunch) async {
        guard let appFound = sharedModel.apps.first(where: { $0.appInfo.relativeBundlePath == launch.bundleId }) else {
            await MainActor.run { alertMessage = "lc.appList.appNotFoundError".loc }
            return
        }
        if appFound.appInfo.isLocked {
            do {
                guard try await LCUtils.authenticateUser() else { return }
            } catch {
                await MainActor.run { alertMessage = error.localizedDescription }
                return
            }
        }
        do {
            try await appFound.runApp(multitask: nil, containerFolderName: launch.containerFolderName, urlStr: launch.urlStr, forceJIT: launch.forceJIT)
        } catch {
            await MainActor.run { alertMessage = error.localizedDescription }
        }
    }

    // MARK: - Delete / rename

    private func deleteApp(_ app: LCAppModel) {
        do {
            try LCAppModel.uninstallFiles(for: app, removeDataFolders: true)
            let id = LCDesktopIcon.appID(for: app)
            sharedModel.apps.removeAll { $0 == app }
            orderStore.remove(id: id)
            dockStore.removeEverywhere(id: id)
            metaStore.remove(id: id)
            showDeleteConfirm = false
            appPendingDelete = nil
            showDetail = false
            detailApp = nil
            syncDesktopOrder()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - Drag & drop

    /// Convert a drag-gesture point from the attaching cell's local
    /// space to "desktop" space (0.0.6). The gesture's
    /// coordinateSpace: parameter is NOT honoured for these gestures
    /// (sequenced LongPress -> Drag, inside TabView pages): values
    /// arrive in the cell's local space, and 0.0.5 trusted the
    /// parameter and fed them to the ghost as desktop points, so the
    /// ghost landed hundreds of points away from the finger. Adding
    /// the cell's frame origin (reported in desktop space by the same
    /// GeometryReader the ghost uses) gives the true finger position,
    /// and stays correct across edge flips because the frame is read
    /// fresh on every move. Falls back to the raw value when the frame
    /// is not (yet) known.
    private func desktopPoint(_ local: CGPoint, iconID: String) -> CGPoint {
        if let frame = dragState.cellFrames[iconID] {
            return CGPoint(x: frame.minX + local.x, y: frame.minY + local.y)
        }
        return local
    }

    private func editDragGesture(for icon: LCDesktopIcon) -> some Gesture {
        // 0.0.6: no coordinateSpace: — values arrive in the cell's
        // local space (see desktopPoint above); the old
        // .named("desktop") was silently ignored, so the ghost did not
        // follow the finger. The per-frame conversion below keeps the
        // location valid across edge flips too (the frame moves with
        // the cell), so no page-width teleport.
        DragGesture(minimumDistance: LCDesktopDragState.dragStartDistance)
            .onChanged { value in
                if dragState.draggedID == nil {
                    if let slot = orderStore.order.firstIndex(of: icon.id) {
                        dragOrigin = .grid(slot: slot)
                    }
                    dragState.beginDrag(id: icon.id, at: desktopPoint(value.startLocation, iconID: icon.id))
                }
                updateGridDrag(translation: value.translation, location: desktopPoint(value.location, iconID: icon.id))
            }
            .onEnded { _ in
                handleDrop()
            }
    }

    /// Shared per-frame drag update: ghost position, hover and the
    /// edge-flip check. Used by the edit-mode drag and by the
    /// normal-mode long-press drag (item 7).
    private func updateGridDrag(translation: CGSize, location: CGPoint) {
        dragState.updateDrag(translation: translation, location: location)
        if let direction = dragState.edgeDirection(at: location, screenWidth: UIScreen.main.bounds.width),
           dragState.edgeFlipReady() {
            dragState.markEdgeFlip()
            flipPage(direction)
        }
    }

    private func handleDrop() {
        guard let draggedID = dragState.draggedID else {
            dragState.endDrag()
            return
        }
        let drop = dragState.resolveDrop()
        withAnimation(.spring(response: LCDesktopDragState.landingDuration, dampingFraction: 1.0)) {
            switch drop {
            case .gridSlot(let slot):
                // 0.0.5: dropping on the fixed Settings icon is a
                // no-op (fly back) — system icons never swap and are
                // never a landing slot.
                if let targetID = orderStore.order.indices.contains(slot) ? orderStore.order[slot] : nil,
                   LCDesktopIcon.isSystemID(targetID) {
                    break
                }
                if case .dock(let originSlot) = dragOrigin {
                    // Dock -> grid: leave the Dock, land in the slot.
                    dockStore.removeFromDock(id: draggedID)
                    if let targetID = orderStore.order.indices.contains(slot) ? orderStore.order[slot] : nil,
                       !targetID.isEmpty, targetID != draggedID {
                        orderStore.swap(id: draggedID, withID: targetID)
                    } else {
                        orderStore.moveToSlot(id: draggedID, slot: slot)
                    }
                    _ = originSlot
                } else if let targetID = orderStore.order.indices.contains(slot) ? orderStore.order[slot] : nil,
                          !targetID.isEmpty, targetID != draggedID {
                    orderStore.swap(id: draggedID, withID: targetID)
                } else {
                    orderStore.moveToSlot(id: draggedID, slot: slot)
                }
            case .dockSlot(let slot):
                if case .dock(let originSlot) = dragOrigin {
                    // Dock -> Dock: reorder within the Dock.
                    if slot < dockStore.dockIDs.count {
                        dockStore.moveDockIcon(from: originSlot, to: slot)
                    }
                } else if slot < dockStore.dockIDs.count {
                    // Grid -> occupied Dock slot: swap; the displaced
                    // Dock icon goes back to the dragged icon's origin cell.
                    let displaced = dockStore.dockIDs[slot]
                    dockStore.replaceDockIcon(at: slot, with: draggedID)
                    orderStore.remove(id: draggedID)
                    if case .grid(let originSlot) = dragOrigin {
                        orderStore.moveToSlot(id: displaced, slot: originSlot)
                    } else {
                        orderStore.placeInFirstFreeSlot(id: displaced)
                    }
                } else {
                    // Grid -> empty Dock slot: same as append.
                    orderStore.remove(id: draggedID)
                    if let evicted = dockStore.addToDock(id: draggedID) {
                        orderStore.placeInFirstFreeSlot(id: evicted)
                    }
                }
            case .dockAppend:
                orderStore.remove(id: draggedID)
                if let evicted = dockStore.addToDock(id: draggedID) {
                    orderStore.placeInFirstFreeSlot(id: evicted)
                }
            case .none:
                // No target: fly back — no state change.
                break
            }
        }
        dragOrigin = nil
        dragState.endDrag()
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            WallpaperView(parallaxOffset: -12 * CGFloat(currentPage))
                .animation(.spring(response: 0.55, dampingFraction: 0.75), value: currentPage)

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    ForEach(0..<pageCount, id: \.self) { page in
                        desktopPage(page)
                            .tag(page)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Hand-drawn page dots: tappable, hidden on one page.
                if pageCount > 1 {
                    HStack(spacing: 8) {
                        ForEach(0..<pageCount, id: \.self) { page in
                            Circle()
                                .fill(page == currentPage ? Color.white : Color.white.opacity(0.4))
                                .frame(width: page == currentPage ? 8 : 7, height: page == currentPage ? 8 : 7)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.52, dampingFraction: 0.75)) {
                                        currentPage = page
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 8)
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: currentPage)
                }
            }
            // Notification-centre nudge: the page follows the finger a
            // little and springs back (see pullDownGesture).
            .offset(y: nudgeState.bounceOffset)

            // Edit-mode chrome: "+" top-left, "···" top-right.
            if editState.isEditing {
                VStack {
                    HStack {
                        EditModePlusCapsule {
                            coachMarkDismissed = true
                            showPicker = true
                        }
                        Spacer()
                        EditModeMenu {
                            editState.exit()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    Spacer()
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
                .animation(.spring(response: 0.34, dampingFraction: 0.6), value: editState.isEditing)
            }

            // Empty-desktop coach mark: once, beside the "+" capsule.
            if showCoachMark {
                VStack {
                    HStack {
                        EmptyStateCoachMark {
                            coachMarkDismissed = true
                        }
                        .padding(.leading, 64)
                        Spacer()
                    }
                    .padding(.top, 64)
                    Spacer()
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }

            // Notification-centre toast (first pull-down only).
            if let toast = nudgeState.toast {
                VStack {
                    NotificationCenterToast(text: toast)
                    Spacer()
                }
                .transition(.opacity)
            }

            // Pull-down search overlay.
            if showSearch {
                SearchOverlay(
                    apps: searchableApps,
                    isPresented: $showSearch,
                    onSelect: { model in
                        launchDesktopApp(model)
                    }
                )
                .transition(.opacity)
            }

            // Control center (JIT tile only).
            if showControlCenter {
                ControlCenterView(isPresented: $showControlCenter, jitEnabled: jitEnabledForControlCenter)
            }

            // App switcher (running apps only; 0.0.5 native windows
            // with live-screen cards).
            if showSwitcher {
                AppSwitcherView(
                    apps: switcherApps,
                    onOpen: { app in
                        showSwitcher = false
                        launchDesktopApp(app)
                    },
                    onClose: { app in
                        switcherApps.removeAll { $0 == app }
                        if switcherApps.isEmpty {
                            showSwitcher = false
                        }
                    },
                    onDismiss: {
                        showSwitcher = false
                    }
                )
            }

            // Install progress pill, top centre.
            if installFlow.isInstalling {
                VStack {
                    InstallProgressPill(installFlow: installFlow)
                    Spacer()
                }
                .transition(.opacity)
                .animation(.easeOut(duration: 0.5), value: installFlow.isInstalling)
            }

        }
        .coordinateSpace(name: "desktop")
        .safeAreaInset(edge: .bottom) {
            DesktopDockView(
                dockIcons: dockIcons,
                isEditing: editState.isEditing,
                draggedID: dragState.draggedID,
                dragState: dragState,
                onTap: { icon in
                    if let model = icon.appModel {
                        launchDesktopApp(model, zoomFrom: icon)
                    }
                },
                onMenuRequest: { icon, slot in
                    if let frame = dragState.dockSlotFrames[slot] {
                        menuRequest = DesktopMenuRequest(
                            icon: icon,
                            anchor: CGPoint(x: frame.midX, y: frame.midY)
                        )
                    }
                },
                onDragBegin: { icon, slot in
                    dragOrigin = .dock(slot: slot)
                },
                onDragUpdate: { _ in
                    if let direction = dragState.edgeDirection(at: dragState.dragLocation, screenWidth: UIScreen.main.bounds.width),
                       dragState.edgeFlipReady() {
                        dragState.markEdgeFlip()
                        flipPage(direction)
                    }
                },
                onDragEnd: {
                    handleDrop()
                }
            )
            // The Dock never moves when the keyboard rises (search).
            .ignoresSafeArea(.keyboard)
        }
        // 0.0.5: the drag ghost and the launch zoom live in an overlay
        // ABOVE the Dock, not inside the ZStack. The Dock is attached
        // via .safeAreaInset, whose content renders above everything
        // in the ZStack — so a ghost starting on a Dock icon was
        // covered by the Dock until the finger left its top edge
        // (it looked like the icon came out from under the Dock), and
        // the launch zoom was half-covered the same way. An overlay
        // attached after .safeAreaInset draws above the inset, so the
        // ghost is under the finger from the first frame. The ghost's
        // .position is in the "desktop" coordinate space (the ZStack's
        // full-screen frame), which is the same frame this overlay
        // covers — no translation needed. Both children are
        // hit-test disabled, so the overlay never eats touches.
        .overlay {
            // Drag ghost, following the finger. It reads its own
            // position object (dragState.position), so per-frame
            // finger movement re-renders only the ghost, not this
            // body — see LCDesktopDragPosition.
            if let draggedID = dragState.draggedID,
               let icon = modelByID[draggedID].map({ LCDesktopIcon.app($0) }) {
                DesktopDragGhost(
                    icon: icon,
                    displayName: metaStore.displayName(for: draggedID, fallback: icon.displayName),
                    position: dragState.position
                )
            }
            // Launch zoom overlay.
            if zoomState.isActive {
                LaunchZoomOverlay(zoom: zoomState, icon: zoomIconImage)
            }
        }
        // 0.0.5: the custom long-press menu (item 7). A separate
        // overlay above the ghost so it is never covered; its dim
        // background eats taps (dismiss) and blocks the desktop
        // underneath while it is open.
        .overlay {
            if let request = menuRequest {
                DesktopAppMenuOverlay(
                    request: request,
                    onOpen: {
                        menuRequest = nil
                        if let model = request.icon.appModel {
                            launchDesktopApp(model, zoomFrom: request.icon)
                        }
                    },
                    onRename: {
                        menuRequest = nil
                        if let model = request.icon.appModel {
                            renameApp = model
                            showRename = true
                        }
                    },
                    onDetail: {
                        menuRequest = nil
                        if let model = request.icon.appModel {
                            detailApp = model
                            showDetail = true
                        }
                    },
                    onDelete: {
                        menuRequest = nil
                        if let model = request.icon.appModel {
                            appPendingDelete = model
                            showDeleteConfirm = true
                        }
                    },
                    onEditHomeScreen: {
                        menuRequest = nil
                        editState.enter()
                    },
                    onDismiss: { menuRequest = nil }
                )
            }
        }
        // Pull-down zones: simultaneous, so TabView paging (horizontal)
        // and the background tap / long-press still work — this handler
        // only answers predominantly vertical drags (see pullDownGesture).
        .simultaneousGesture(pullDownGesture())
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SealBoxOpenAppSwitcher"))) { _ in
            // Posted by SettingsView's Home Bar (double-tap / hold /
            // swipe-up pause): dismiss the settings page first (RootView
            // clears requestedSystemPage when the cover closes), then
            // show the switcher over the desktop.
            openSwitcher()
        }
        .onPreferenceChange(CellFrameKey.self) { frames in
            dragState.cellFrames = frames
        }
        .onPreferenceChange(SlotFrameKey.self) { frames in
            dragState.slotFrames = frames
        }
        .onPreferenceChange(DockSlotFrameKey.self) { frames in
            dragState.dockSlotFrames = frames
        }
        .onAppear {
            syncDesktopOrder()
            consumePendingRequests()
        }
        .onChange(of: sharedModel.apps) { _ in
            syncDesktopOrder()
        }
        .onChange(of: currentPage) { _ in
            // 0.0.5: a page swipe behind the open long-press menu
            // would leave the menu anchored to an icon that is no
            // longer on screen — dismiss it with the page.
            menuRequest = nil
        }
        .onChange(of: installFlow.installedAppIDs) { _ in
            syncDesktopOrder()
            // New icon lands on the last page.
            withAnimation(.spring(response: 0.52, dampingFraction: 0.75)) {
                currentPage = max(0, pageCount - 1)
            }
        }
        .onChange(of: installFlow.pendingInstallURL) { _ in
            consumePendingRequests()
        }
        .onChange(of: installFlow.pendingLaunch) { _ in
            consumePendingRequests()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                // A drag in progress is cancelled, never left half-way.
                dragState.endDrag()
                dragOrigin = nil
            }
        }
        .sheet(isPresented: $showPicker) {
            IPADocumentPicker { url in
                Task { await installFlow.installFromUrl(urlStr: url.absoluteString) }
            }
        }
        .sheet(isPresented: $showCertSheet) {
            CertificateGateView(onCertificateImported: {
                showCertSheet = false
            })
        }
        .sheet(isPresented: $showDetail) {
            if let app = detailApp {
                AppDetailView(
                    app: app,
                    onDelete: {
                        appPendingDelete = app
                        showDetail = false
                        showDeleteConfirm = true
                    },
                    onRename: {
                        renameApp = app
                        showDetail = false
                        showRename = true
                    },
                    onDone: {
                        showDetail = false
                    }
                )
            }
        }
        .sheet(isPresented: $showRename) {
            if let app = renameApp {
                RenameSheet(
                    app: app,
                    initialName: metaStore.displayName(for: LCDesktopIcon.appID(for: app), fallback: app.displayName),
                    onSave: { name in
                        metaStore.setDisplayName(name, for: LCDesktopIcon.appID(for: app))
                        showRename = false
                    },
                    onCancel: {
                        showRename = false
                    }
                )
            }
        }
        .sheet(isPresented: $showDeleteConfirm) {
            if let app = appPendingDelete {
                DeleteConfirmSheet(
                    app: app,
                    onConfirm: { deleteApp(app) },
                    onCancel: { showDeleteConfirm = false }
                )
            }
        }
        .confirmationDialog(
            "lc.install.replaceTitle",
            isPresented: Binding(
                get: { installFlow.installOptions != nil },
                set: { if !$0 { installFlow.chooseReplaceOption(nil) } }
            )
        ) {
            if let options = installFlow.installOptions {
                ForEach(options, id: \.self) { option in
                    Button(option.isReplace
                           ? "lc.install.replace %@".localizeWithFormat(option.appToReplace?.displayName ?? "")
                           : "lc.install.parallel".loc) {
                        installFlow.chooseReplaceOption(option)
                    }
                }
                Button("lc.common.cancel".loc, role: .cancel) {
                    installFlow.chooseReplaceOption(nil)
                }
            }
        }
        .alert(
            "lc.common.error",
            isPresented: Binding(
                get: { alertMessage != nil || installFlow.errorMessage != nil },
                set: { if !$0 { alertMessage = nil; installFlow.errorMessage = nil } }
            )
        ) {
            Button("lc.common.ok".loc, action: {})
        } message: {
            Text(alertMessage ?? installFlow.errorMessage ?? "")
        }
    }

    private func consumePendingRequests() {
        if let urlString = installFlow.consumePendingInstall() {
            Task { await installFlow.startInstallFromUrlString(urlString) }
        }
        if let launch = installFlow.consumePendingLaunch() {
            Task { await launchAppWithBundleId(launch) }
        }
    }

    // MARK: - One page

    @ViewBuilder
    private func desktopPage(_ page: Int) -> some View {
        let slotIDs = pageSlotIDs(page)
        ZStack {
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(0..<Self.iconsPerPage, id: \.self) { cell in
                    let slot = page * Self.iconsPerPage + cell
                    let id = slotIDs[cell]
                    if id.isEmpty {
                        Color.clear
                            .frame(height: 78)
                            .background(
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: SlotFrameKey.self,
                                        value: [slot: geometry.frame(in: .named("desktop"))]
                                    )
                                }
                            )
                    } else if id == LCSystemPage.settings.id {
                        // 0.0.5: the fixed Settings entry (first page,
                        // first cell). Rendered from the order like any
                        // icon, but it is not an app — see gridCell.
                        gridCell(.system(.settings), slot: slot)
                    } else if let model = modelByID[id] {
                        let icon = LCDesktopIcon.app(model)
                        gridCell(icon, slot: slot)
                    } else {
                        Color.clear.frame(height: 78)
                    }
                }
            }
            .padding(.horizontal, 16)
            .animation(.spring(response: 0.38, dampingFraction: 0.6), value: slotIDs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    editState.blankTapped()
                }
                .onLongPressGesture(minimumDuration: LCDesktopDragState.longPressDuration) {
                    editState.enter()
                }
        )
    }

    @ViewBuilder
    private func gridCell(_ icon: LCDesktopIcon, slot: Int) -> some View {
        let id = icon.id
        let name = metaStore.displayName(for: id, fallback: icon.displayName)
        let cell = DesktopGridCell(
            icon: icon,
            displayName: name,
            isEditing: editState.isEditing,
            isDragged: dragState.draggedID == id,
            isDropHover: dragState.hoverIconID == id,
            isLifted: liftedID == id,
            onDelete: {
                if let model = icon.appModel {
                    appPendingDelete = model
                    showDeleteConfirm = true
                }
            },
            onTap: {
                if let model = icon.appModel {
                    launchDesktopApp(model, zoomFrom: icon)
                } else if case .system(.settings) = icon {
                    // 0.0.5: the fixed desktop Settings entry opens
                    // the settings page (RootView's fullScreenCover
                    // is bound to requestedSystemPage == .settings).
                    sharedModel.requestedSystemPage = .settings
                }
            }
        )
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .background(
            GeometryReader { geometry in
                Color.clear
                    .preference(key: CellFrameKey.self, value: [id: geometry.frame(in: .named("desktop"))])
                    .preference(key: SlotFrameKey.self, value: [slot: geometry.frame(in: .named("desktop"))])
            }
        )
        if icon.isSystem {
            // Fixed system icon: no drag gesture, no context menu —
            // it never moves, never deletes, never enters the Dock.
            // It still jiggles in edit mode like a native icon.
            cell
        } else if editState.isEditing {
            // 0.0.4: high-priority so the icon drag wins over the
            // TabView's paging gesture — with a plain .gesture a
            // horizontal drag could page the desktop instead and the
            // drag-start point went stale under the moving page.
            // A page swipe can still start from any blank area, and
            // the edge hot zones still flip pages mid-drag.
            cell.highPriorityGesture(editDragGesture(for: icon))
        } else {
            // Normal mode: the Button's tap opens the app; the
            // long-press gesture (item 7) owns the long-press — lift,
            // drag, or menu on release. It must be high-priority so
            // it wins over the desktop's pull-down / control-centre
            // gestures and over the Button's own press.
            // The old system contextMenu is gone: it owned the
            // long-press touch and made hold-through dragging
            // impossible. The menu is now the custom overlay
            // (DesktopAppMenuOverlay) shown on a long-press release.
            cell.highPriorityGesture(longPressDragGesture(for: icon))
        }
    }

    /// Normal-mode long-press drag (item 7, iOS behaviour): press
    /// 0.45 s and the icon lifts in place; move and it drags (the
    /// same finger, no lift); release without moving and the menu
    /// opens. A quick tap still opens the app (the Button owns it:
    /// the long-press fails on touch-up before 0.45 s).
    private func longPressDragGesture(for icon: LCDesktopIcon) -> some Gesture {
        // 0.0.6: no coordinateSpace: — the sequenced DragGesture
        // reports in the cell's local space (see desktopPoint); the
        // old .named("desktop") was silently ignored, so the ghost
        // started hundreds of points from the finger the moment the
        // drag began ("只变大图标，按住拖起来偏移巨大").
        LongPressGesture(minimumDuration: LCDesktopDragState.longPressDuration)
            .sequenced(before: DragGesture(minimumDistance: LCDesktopDragState.dragStartDistance))
            .onChanged { value in
                switch value {
                case .first(let pressed):
                    if pressed {
                        liftedID = icon.id
                        menuCandidateID = icon.id
                    }
                case .second(true, let drag):
                    guard let drag else { return }
                    if dragState.draggedID == nil {
                        if let slot = orderStore.order.firstIndex(of: icon.id) {
                            dragOrigin = .grid(slot: slot)
                        }
                        dragState.beginDrag(id: icon.id, at: desktopPoint(drag.startLocation, iconID: icon.id))
                        liftedID = nil
                        menuCandidateID = nil
                    }
                    updateGridDrag(translation: drag.translation, location: desktopPoint(drag.location, iconID: icon.id))
                default:
                    break
                }
            }
            .onEnded { value in
                liftedID = nil
                switch value {
                case .second(true, _):
                    if dragState.draggedID != nil {
                        handleDrop()
                    } else if menuCandidateID == icon.id,
                              let anchor = iconCenter(for: icon) {
                        menuRequest = DesktopMenuRequest(icon: icon, anchor: anchor)
                    }
                default:
                    break
                }
                menuCandidateID = nil
            }
    }
}
