//
//  LCAppSwitcherView.swift
//  LiveContainerSwiftUI
//
//  SealBox 原生后台切换器（开发文档 §10.2 定稿、§14 动画规范）。
//
//  定稿规则（不得自行改动，见文档 §10.2）：
//  - 层级固定右边盖左边：zIndex = 100 + index * 4，焦点卡不置顶、不翻转；
//    仅上滑关闭中正在飞出的卡可临时置顶（zIndex 1000）。
//  - 所有卡片大小一模一样，由同一组定宽/定高决定；恒上下居中、同一高度；
//    轨道上下各留 54px 安全距离，不贴顶、不贴底。
//  - 横拖 1:1 跟手；松手带初速度的柔和弹簧一档一档吸附（轨迹与帧率无关）。
//  - 点卡片从该卡实测大小原地放大成全屏（起始帧与卡片真实宽度同源计算，
//    不先缩后长）；上滑卡片飞出关闭，飞出后不再出现；最后一张划掉直接回桌面。
//  - 点空白或下滑回桌面走单条时间线，无重影、无闪烁；卡片无边框。
//  - 每张卡上方居中显示图标 + 名称。
//  - 卡片预览只用真实内容：设置卡用迷你真实设置列表，插件卡用真实状态行；
//    客 App 若无可用的实时快照，显示图标 + 名称 + 中性预览区，绝不画假截图、
//    绝不编假数据。
//  - 动画只写 transform / opacity；手势采样与样式写入按帧合并（文档 §14，
//    见 LCSealBoxHomeBar.swift 的 LCFrameSampler）。
//
//  卡片来源（真实注册表，不编造）：
//  - 多任务窗口：MultitaskWindowManager.appDict（WindowGroup 场景，iOS 16.1+）
//    与 MultitaskDockManager.shared.apps（进程内虚拟窗口，iOS 16.0+）；
//  - 当前打开的系统页（调用方传入）。
//  经典模式下客 App 运行时容器 UI 不存在，切换器看不到它——这是架构事实，
//  不是本文件的缺口（见汇报）。卡片为空时显示中性空状态，不拼凑假卡片。
//
//  未编译、未真机验证（本机无 Xcode/Swift）：dismissWindow 的 (id:value:)
//  签名已按 WindowGroup(id: "appView", for: String.self) 对过，iOS 15
//  部署目标的引用问题靠调用点 `if #available(iOS 17.0, *)` 守卫
//  （存储属性上不能加 @available）；场景销毁是否彻底，须在 Mac /
//  CI 上先编后真机走查。
//

import SwiftUI
import UIKit

// MARK: - Cards

/// One guest-app card. Identity is the dataUUID only: the icon is a
/// UIImage (not Hashable) and must not take part in equality.
struct LCAppSwitcherGuestCard: Hashable {
    let dataUUID: String
    let bundleId: String
    let displayName: String
    let icon: UIImage?

    static func == (lhs: LCAppSwitcherGuestCard, rhs: LCAppSwitcherGuestCard) -> Bool {
        lhs.dataUUID == rhs.dataUUID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(dataUUID)
    }
}

/// One card in the switcher: a running guest app, or the currently open
/// system page (Sources / Tweaks / Settings).
enum LCAppSwitcherCard: Identifiable, Hashable {
    case guest(LCAppSwitcherGuestCard)
    case system(LCSystemPage)

    var id: String {
        switch self {
        case .guest(let guest):
            return "guest:\(guest.dataUUID)"
        case .system(let page):
            return page.id
        }
    }

    var title: String {
        switch self {
        case .guest(let guest):
            return guest.displayName
        case .system(let page):
            return page.title
        }
    }

    /// The guest dataUUID, if this is a guest card.
    var guestDataUUID: String? {
        switch self {
        case .guest(let guest):
            return guest.dataUUID
        case .system:
            return nil
        }
    }

    static func == (lhs: LCAppSwitcherCard, rhs: LCAppSwitcherCard) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Mini settings preview, read from the real stored values at refresh
/// time — never invented. See LCAppSwitcherStore.refresh.
struct LCAppSwitcherSettingsPreview: Hashable {
    let jitEnablerName: String
    let themeName: String
    let ignoreJITOnLaunch: Bool

    static func readReal() -> LCAppSwitcherSettingsPreview {
        let rawEnabler = LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")
        let enablerName = JITEnablerType(rawValue: rawEnabler)?.displayName ?? "未设置"
        let rawTheme = LCUtils.appGroupUserDefault.string(forKey: "LCDesktopTheme") ?? ""
        let themeName = LCDesktopTheme(rawValue: rawTheme)?.displayName ?? LCDesktopTheme.system.displayName
        // LCIgnoreJITOnLaunch lives in the standard defaults, same as
        // LCSettingsView's @AppStorage("LCIgnoreJITOnLaunch").
        let ignoreJIT = UserDefaults.standard.bool(forKey: "LCIgnoreJITOnLaunch")
        return LCAppSwitcherSettingsPreview(
            jitEnablerName: enablerName,
            themeName: themeName,
            ignoreJITOnLaunch: ignoreJIT
        )
    }
}

// MARK: - Store

/// Owns the switcher card list. Order is stable across refreshes: cards
/// that are still open keep their slots (so zIndex never reshuffles),
/// new cards append at the end, closed cards drop out.
final class LCAppSwitcherStore: ObservableObject {
    /// zIndex base (§10.2: 100 + index * 4, right always covers left).
    static let zIndexBase = 100
    static let zIndexStep = 4
    /// Temporarily topmost while a card is flying out on close (§10.2:
    /// the only exception to the fixed order).
    static let zIndexFlyingOut = 1000

    @Published private(set) var cards: [LCAppSwitcherCard] = []
    /// Real tweak folder names, for the Tweaks card preview.
    @Published private(set) var tweakNames: [String] = []
    /// Real settings rows, for the Settings card preview.
    @Published private(set) var settingsPreview = LCAppSwitcherSettingsPreview.readReal()

    /// Rebuild the card list from the real open-window registries.
    /// - Parameters:
    ///   - apps: installed app models, for resolving guest icons by bundleId.
    ///   - tweakNames: real tweak folder names (SharedModel.tweakFolderNames).
    ///   - openSystemPage: the system page currently open, if any.
    ///   - darkModeIcon: whether dark icons are in use, for icon lookup.
    func refresh(apps: [LCAppModel], tweakNames: [String], openSystemPage: LCSystemPage?, darkModeIcon: Bool) {
        var fresh: [LCAppSwitcherCard] = []
        var seenUUIDs = Set<String>()

        // In-process virtual windows (multitask virtualWindow mode).
        if #available(iOS 16.0, *) {
            for dockApp in MultitaskDockManager.shared.apps {
                let uuid = dockApp.appUUID
                guard !seenUUIDs.contains(uuid) else {
                    continue
                }
                seenUUIDs.insert(uuid)
                let icon = dockApp.appInfo?.iconIsDarkIcon(darkModeIcon)
                fresh.append(.guest(LCAppSwitcherGuestCard(
                    dataUUID: uuid,
                    bundleId: dockApp.appInfo?.bundleIdentifier() ?? "",
                    displayName: dockApp.appName,
                    icon: icon
                )))
            }
        }
        // WindowGroup scenes ("appView").
        if #available(iOS 16.1, *) {
            for info in MultitaskWindowManager.appDict.values {
                guard !seenUUIDs.contains(info.dataUUID) else {
                    continue
                }
                seenUUIDs.insert(info.dataUUID)
                let model = apps.first { $0.appInfo.bundleIdentifier() == info.bundleId }
                let icon = model?.appInfo.iconIsDarkIcon(darkModeIcon)
                fresh.append(.guest(LCAppSwitcherGuestCard(
                    dataUUID: info.dataUUID,
                    bundleId: info.bundleId,
                    displayName: info.displayName,
                    icon: icon
                )))
            }
        }
        // The currently open system page is a real open card too.
        if let page = openSystemPage {
            fresh.append(.system(page))
        }

        var merged: [LCAppSwitcherCard] = []
        for card in cards where fresh.contains(card) {
            merged.append(card)
        }
        for card in fresh where !merged.contains(card) {
            merged.append(card)
        }
        if merged != cards {
            cards = merged
        }
        self.tweakNames = tweakNames
        settingsPreview = LCAppSwitcherSettingsPreview.readReal()
    }

    func removeCard(_ card: LCAppSwitcherCard) {
        cards.removeAll { $0 == card }
    }

    /// Bring a guest window to the front, mirroring
    /// LCAppModel.bringExistingMultitaskWindowIfNeeded: WindowGroup
    /// scene first, in-process virtual window second.
    func bringGuestToFront(dataUUID: String) -> Bool {
        if #available(iOS 16.1, *) {
            if MultitaskWindowManager.openExistingAppWindow(dataUUID: dataUUID) {
                return true
            }
        }
        if #available(iOS 16.0, *) {
            return MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: dataUUID)
        }
        return false
    }

    /// Close a guest card: drop it from the switcher and from both
    /// open-window registries. The caller (the view) additionally asks
    /// the system to dismiss the WindowGroup scene via dismissWindow.
    /// Whether the LiveProcess scene fully terminates after that must
    /// be verified on a real device (see the file header).
    func closeGuest(dataUUID: String) {
        cards.removeAll { $0.guestDataUUID == dataUUID }
        if #available(iOS 16.1, *) {
            MultitaskWindowManager.appDict.removeValue(forKey: dataUUID)
        }
        if #available(iOS 16.0, *) {
            MultitaskDockManager.shared.removeRunningApp(dataUUID)
        }
    }
}

// MARK: - Drag state (§14: sample on the event, write once per frame)

/// Coalesces switcher drag sampling and style writes to the frame
/// callback (§14). The gesture's onChanged only records the latest
/// translation into LCFrameSampler; the display link publishes it once
/// per frame, and the view derives focus / close offsets from that.
/// Direction locks on first movement so a drag never jumps axes.
final class LCAppSwitcherDragState: ObservableObject {
    enum Axis {
        case horizontal
        case vertical
    }

    /// Latest horizontal translation, published once per frame.
    @Published private(set) var focusOffset: CGFloat = 0
    /// Latest upward translation of a vertical drag (<= 0), published
    /// once per frame. Zero while the drag is horizontal.
    @Published private(set) var closeOffset: CGFloat = 0
    @Published private(set) var axis: Axis?
    @Published private(set) var isDragging = false

    private let sampler = LCFrameSampler()
    private var lastTranslation = CGPoint.zero

    func begin() {
        guard !isDragging else {
            return
        }
        isDragging = true
        axis = nil
        lastTranslation = .zero
        focusOffset = 0
        closeOffset = 0
        sampler.record(.zero)
        sampler.onFrame = { [weak self] point in
            guard let self else {
                return
            }
            self.focusOffset = point.x
            self.closeOffset = point.y
        }
        sampler.start()
    }

    func record(_ translation: CGPoint) {
        guard isDragging else {
            return
        }
        if axis == nil, max(abs(translation.x), abs(translation.y)) > 12 {
            axis = abs(translation.x) > abs(translation.y) ? .horizontal : .vertical
        }
        lastTranslation = translation
        sampler.record(translation)
    }

    func end() {
        sampler.stop()
        isDragging = false
        axis = nil
        focusOffset = 0
        closeOffset = 0
    }
}

// MARK: - View

private struct CardSizePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGSize] = [:]
    static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) {
        value.merge(nextValue()) { $1 }
    }
}

struct LCAppSwitcherView: View {
    /// Track clearance above and below the cards (§10.2: 54px each side).
    static let trackPadding: CGFloat = 54
    /// Fixed spring for snap-to-card settle: time-based, so the track is
    /// the same on 60Hz and 120Hz devices (§14).
    static let settleSpring = Animation.spring(response: 0.38, dampingFraction: 0.85)

    @ObservedObject var store: LCAppSwitcherStore
    var darkModeIcon: Bool
    /// Dismiss the switcher (single timeline: the caller toggles with
    /// one animation; this view adds no second dismiss animation).
    var onDismiss: () -> Void
    /// Open a system page from its card: the caller hides the switcher
    /// and presents the page.
    var onOpenSystem: (LCSystemPage) -> Void

    // dismissWindow is iOS 17.0+, but this target still deploys to
    // iOS 15.0 (LiveContainerSwiftUI: IPHONEOS_DEPLOYMENT_TARGET =
    // 15.0). A stored property cannot be marked potentially
    // unavailable with @available, so the property carries none;
    // the only use is inside `if #available(iOS 17.0, *)` in
    // finishClose. The (id:value:) signature matches
    // WindowGroup(id: "appView", for: String.self) in
    // LiveContainerSwiftUIApp.swift:112.
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var dragState = LCAppSwitcherDragState()

    /// Continuous focus position in card-index space (1.0 = card 1
    /// centred). Fractional while dragging; snapped to an integer on release.
    @State private var focusPosition: CGFloat = 0
    /// Focus position the current drag started from.
    @State private var dragBaseFocus: CGFloat = 0
    /// Measured card size per card id (GeometryReader, same source the
    /// open zoom is computed from).
    @State private var measuredSizes: [String: CGSize] = [:]
    /// Card currently zooming open, if any.
    @State private var openingCardID: String?
    /// Zoom scale of the opening card (1 = card size).
    @State private var openingScale: CGFloat = 1
    /// Opacity of the non-opening cards while one zooms open.
    @State private var othersOpacity: Double = 1
    /// Card currently flying out on close, if any.
    @State private var closingCardID: String?
    /// Fly-out offset of the closing card.
    @State private var closingOffsetY: CGFloat = 0
    /// Fly-out opacity of the closing card.
    @State private var closingOpacity: Double = 1

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let layout = switcherLayout(for: size)
            ZStack {
                // Tap the blank area to go back to the desktop. One
                // animation, owned by the caller (onDismiss).
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture {
                        onDismiss()
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                if value.translation.height > 80,
                                   value.translation.height > abs(value.translation.width) {
                                    onDismiss()
                                }
                            }
                    )

                if store.cards.isEmpty {
                    // No fake cards: nothing is open, say so.
                    Text("暂无正在运行的应用")
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(.ultraThinMaterial))
                } else {
                    cardsLayer(size: size, layout: layout)
                }
            }
            .onAppear {
                focusPosition = CGFloat(max(0, store.cards.count - 1))
            }
            .onChange(of: store.cards.count) { _ in
                // Clamp the focus when cards close; stay on the last
                // card when the focused one was the one that flew out.
                let maxIndex = CGFloat(max(0, store.cards.count - 1))
                if focusPosition > maxIndex {
                    withAnimation(Self.settleSpring) {
                        focusPosition = maxIndex
                    }
                }
            }
            .onChange(of: dragState.focusOffset) { _ in
                guard dragState.isDragging, dragState.axis == .horizontal else {
                    return
                }
                let raw = dragBaseFocus - dragState.focusOffset / layout.stride
                focusPosition = clampedFocus(raw, count: store.cards.count)
            }
            .onPreferenceChange(CardSizePreferenceKey.self) { sizes in
                measuredSizes = sizes
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Layout (one size for every card)

    private struct SwitcherLayout {
        let cardWidth: CGFloat
        let cardHeight: CGFloat
        let stride: CGFloat
    }

    private func switcherLayout(for size: CGSize) -> SwitcherLayout {
        let cardHeight = max(200, size.height - 2 * Self.trackPadding)
        let cardWidth = min(cardHeight * 0.46, size.width * 0.82)
        return SwitcherLayout(cardWidth: cardWidth, cardHeight: cardHeight, stride: cardWidth * 0.55)
    }

    /// Soft edge resistance: past either end the focus moves at 0.3x.
    private func clampedFocus(_ raw: CGFloat, count: Int) -> CGFloat {
        guard count > 1 else {
            return 0
        }
        let maxIndex = CGFloat(count - 1)
        if raw < 0 {
            return raw * 0.3
        }
        if raw > maxIndex {
            return maxIndex + (raw - maxIndex) * 0.3
        }
        return raw
    }

    private var focusedIndex: Int {
        guard !store.cards.isEmpty else {
            return 0
        }
        return max(0, min(store.cards.count - 1, Int(focusPosition.rounded())))
    }

    // MARK: Cards layer

    private func cardsLayer(size: CGSize, layout: SwitcherLayout) -> some View {
        ZStack {
            ForEach(Array(store.cards.enumerated()), id: \.element.id) { index, card in
                cardColumn(card: card, index: index, size: size, layout: layout)
            }
        }
        // One drag gesture for the whole track: horizontal swipe moves
        // focus, vertical swipe on the focused card closes it. The axis
        // locks on first movement (dragState), so a drag never jumps.
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    if !dragState.isDragging {
                        dragBaseFocus = focusPosition
                        dragState.begin()
                    }
                    dragState.record(CGPoint(x: value.translation.width, y: value.translation.height))
                }
                .onEnded { value in
                    endDrag(value: value, layout: layout)
                }
        )
    }

    private func cardColumn(card: LCAppSwitcherCard, index: Int, size: CGSize, layout: SwitcherLayout) -> some View {
        let isOpening = openingCardID == card.id
        let isClosing = closingCardID == card.id
        let isFocused = index == focusedIndex
        // §10.2 zIndex: 100 + index * 4, right always covers left.
        // The focused card does NOT rise; only the flying-out card does.
        let zIndex: Double = isClosing
            ? Double(LCAppSwitcherStore.zIndexFlyingOut)
            : Double(LCAppSwitcherStore.zIndexBase + index * LCAppSwitcherStore.zIndexStep)
        let xOffset = (CGFloat(index) - focusPosition) * layout.stride
        let yOffset: CGFloat = {
            if isClosing {
                return closingOffsetY
            }
            if isFocused, dragState.axis == .vertical {
                return min(0, dragState.closeOffset)
            }
            return 0
        }()
        return VStack(spacing: 10) {
            cardHeader(card: card)
            cardBody(card: card, layout: layout)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CardSizePreferenceKey.self,
                            value: [card.id: proxy.size]
                        )
                    }
                )
        }
        .offset(x: xOffset, y: yOffset)
        .scaleEffect(isOpening ? openingScale : 1, anchor: .center)
        .opacity(isClosing ? closingOpacity : (isOpening ? 1 : othersOpacity))
        .zIndex(zIndex)
        .onTapGesture {
            openCard(card, size: size, layout: layout)
        }
    }

    // MARK: Card header (icon + name, centred above every card)

    private func cardHeader(card: LCAppSwitcherCard) -> some View {
        HStack(spacing: 8) {
            cardIconView(card: card, size: 28)
            Text(card.title)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
    }

    private func cardIconView(card: LCAppSwitcherCard, size: CGFloat) -> some View {
        Group {
            switch card {
            case .guest(let guest):
                if let icon = guest.icon {
                    IconImageView(icon: icon)
                        .frame(width: size, height: size)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                        .foregroundStyle(.white)
                }
            case .system(let page):
                Image(systemName: page.systemImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: Card body (real content only, no fake screenshots)

    private func cardBody(card: LCAppSwitcherCard, layout: SwitcherLayout) -> some View {
        Group {
            switch card {
            case .guest(let guest):
                guestPreview(guest: guest, layout: layout)
            case .system(let page):
                switch page {
                case .settings:
                    settingsPreview(layout: layout)
                case .tweaks:
                    tweaksPreview(layout: layout)
                case .sources:
                    neutralPreview(card: card, layout: layout)
                }
            }
        }
        // No border (§10.2). One shadow spec for every card, never
        // restyled mid-animation (§14).
        .frame(width: layout.cardWidth, height: layout.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
    }

    /// Guest apps have no usable live snapshot in this process, so the
    /// preview is a neutral area with the real icon — never a drawn
    /// fake screenshot and never invented content.
    private func guestPreview(guest: LCAppSwitcherGuestCard, layout: SwitcherLayout) -> some View {
        ZStack {
            Color(.systemGray5)
            VStack(spacing: 12) {
                if let icon = guest.icon {
                    IconImageView(icon: icon)
                        .frame(width: 72, height: 72)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Neutral preview for cards with no real list to show (Sources):
    /// icon + name only, no invented rows.
    private func neutralPreview(card: LCAppSwitcherCard, layout: SwitcherLayout) -> some View {
        ZStack {
            Color(.systemGray5)
            cardIconView(card: card, size: 64)
        }
    }

    /// Settings card: a mini list of the real stored settings rows.
    private func settingsPreview(layout: SwitcherLayout) -> some View {
        let preview = store.settingsPreview
        return ZStack(alignment: .topLeading) {
            Color(.systemBackground)
            VStack(alignment: .leading, spacing: 0) {
                previewRow(title: "JIT 方式", value: preview.jitEnablerName)
                Divider()
                previewRow(title: "主题", value: preview.themeName)
                Divider()
                previewRow(title: "启动时忽略 JIT", value: preview.ignoreJITOnLaunch ? "开" : "关")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
    }

    /// Tweaks card: the real tweak folder names, or the §12.4 empty state.
    private func tweaksPreview(layout: SwitcherLayout) -> some View {
        let names = store.tweakNames
        return ZStack(alignment: .topLeading) {
            Color(.systemBackground)
            if names.isEmpty {
                Text("暂无内容")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(names.prefix(4)), id: \.self) { name in
                        previewRow(title: name, value: "")
                        Divider()
                    }
                    if names.count > 4 {
                        Text("还有 \(names.count - 4) 个")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
    }

    private func previewRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            if !value.isEmpty {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: Drag end (snap, or close)

    private func endDrag(value: DragGesture.Value, layout: SwitcherLayout) {
        let wasVertical = dragState.axis == .vertical
        let closeOffset = dragState.closeOffset
        dragState.end()
        guard !store.cards.isEmpty else {
            return
        }
        if wasVertical, closeOffset < -90 {
            // Swipe the focused card up to close it.
            closeCard(store.cards[focusedIndex])
            return
        }
        // Snap to the nearest card with a velocity-aware spring, one
        // card at a time (§10.2: soft spring, frame-rate independent).
        let predicted = dragBaseFocus - value.predictedEndTranslation.width / layout.stride
        let target = clampedFocus(predicted, count: store.cards.count).rounded()
        let clampedTarget = max(0, min(CGFloat(store.cards.count - 1), target))
        withAnimation(Self.settleSpring) {
            focusPosition = clampedTarget
        }
    }

    // MARK: Close a card (fly out, then remove for good)

    private func closeCard(_ card: LCAppSwitcherCard) {
        guard closingCardID == nil else {
            return
        }
        closingCardID = card.id
        closingOffsetY = 0
        closingOpacity = 1
        // Fly out: straight up off the screen, fading. Only this card
        // is topmost while flying (§10.2).
        withAnimation(.easeInOut(duration: 0.3)) {
            closingOffsetY = -UIScreen.main.bounds.height
            closingOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [card] in
            finishClose(card: card)
        }
    }

    private func finishClose(card: LCAppSwitcherCard) {
        closingCardID = nil
        closingOffsetY = 0
        closingOpacity = 1
        switch card {
        case .guest(let guest):
            store.closeGuest(dataUUID: guest.dataUUID)
            // Ask the system to dismiss the WindowGroup scene. The
            // scene may need its own terminate to fully die — verify
            // on a real device (see the file header).
            if #available(iOS 17.0, *) {
                dismissWindow(id: "appView", value: guest.dataUUID)
            }
        case .system:
            // The system page is closed by the caller: removing the
            // card here is enough; the caller re-opens the desktop.
            store.removeCard(card)
        }
        // The last card swiped away goes straight back to the desktop.
        if store.cards.isEmpty {
            onDismiss()
        }
    }

    // MARK: Open a card (zoom from its measured size to full screen)

    private func openCard(_ card: LCAppSwitcherCard, size: CGSize, layout: SwitcherLayout) {
        guard openingCardID == nil, closingCardID == nil else {
            return
        }
        // Start frame and real card width come from the same measured
        // source (CardSizePreferenceKey): never shrink-then-grow.
        let measured = measuredSizes[card.id] ?? CGSize(width: layout.cardWidth, height: layout.cardHeight)
        let scale = max(size.width / max(1, measured.width), size.height / max(1, measured.height))
        openingCardID = card.id
        withAnimation(.easeInOut(duration: 0.32)) {
            openingScale = scale
            othersOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [card] in
            openingCardID = nil
            openingScale = 1
            othersOpacity = 1
            switch card {
            case .guest(let guest):
                if store.bringGuestToFront(dataUUID: guest.dataUUID) {
                    onDismiss()
                } else {
                    // Stale card: the window is gone, drop the card.
                    store.removeCard(card)
                }
            case .system(let page):
                onOpenSystem(page)
            }
        }
    }
}
