// 桌面拖动状态机：长按起拖、边缘翻页、落位与飞回动画的时序与阈值。
import SwiftUI

/// 桌面拖动状态，由 SBDesktopView 持有并传给 Dock 与各 Cell。
final class SBDesktopDragState: ObservableObject {
    // MARK: - 契约常量（brief 逐项落实）
    static let longPressDuration: TimeInterval = 0.45
    static let dragStartDistance: CGFloat = 7
    static let pressCancelDistance: CGFloat = 9
    static let ghostScale: CGFloat = 1.15
    static let edgeHotZoneWidth: CGFloat = 24
    static let edgeHoverDelay: TimeInterval = 0.65
    static let dropDuration: TimeInterval = 0.42
    static let flyBackDuration: TimeInterval = 0.45

    // MARK: - 状态
    @Published var draggedBundleID: String?
    @Published var dragLocation: CGPoint = .zero
    @Published var placeholderPage: Int = 0
    @Published var placeholderIndex: Int = 0
    @Published var isDragging: Bool = false
    @Published var hasValidDropTarget: Bool = false
    @Published private(set) var isLongPressArmed: Bool = false

    private var dragStartLocation: CGPoint = .zero
    private var edgeHoverStart: Date?
    private var edgeHoverDirection: Int = 0 // -1 上一页，+1 下一页，0 不在热区

    var draggedAppBundleID: String? { draggedBundleID }

    // MARK: - 长按
    /// 长按 0.45s 到时调用：进入“已武装”态，等待手指移动超过 7pt 才真正起拖。
    func armLongPress(bundleID: String, at location: CGPoint) {
        draggedBundleID = bundleID
        dragStartLocation = location
        dragLocation = location
        isLongPressArmed = true
        isDragging = false
    }

    func disarmLongPress() {
        guard !isDragging else { return }
        isLongPressArmed = false
        draggedBundleID = nil
    }

    // MARK: - 拖动
    /// 拖动中更新位置；移动超过 7pt 起拖，超过 9pt 的按压已由 Cell 侧取消。
    /// 返回 true 表示本次移动已起拖。
    @discardableResult
    func updateDrag(to location: CGPoint) -> Bool {
        dragLocation = location
        if !isDragging {
            let moved = hypot(location.x - dragStartLocation.x, location.y - dragStartLocation.y)
            guard moved > Self.dragStartDistance else { return false }
            isDragging = true
        }
        return isDragging
    }

    /// 根据落点换算占位格；调用方把换算出的页/格传进来，状态机只记结果。
    func updatePlaceholder(page: Int, index: Int, hasValidTarget: Bool) {
        placeholderPage = page
        placeholderIndex = index
        hasValidDropTarget = hasValidTarget
    }

    /// 边缘 24pt 热区：悬停满 0.65s 返回翻页方向（-1 / +1），否则返回 0。
    func edgePageDirection(at location: CGPoint, in size: CGSize, now: Date = Date()) -> Int {
        let direction: Int
        if location.x < Self.edgeHotZoneWidth {
            direction = -1
        } else if location.x > size.width - Self.edgeHotZoneWidth {
            direction = 1
        } else {
            direction = 0
        }
        if direction == 0 {
            edgeHoverStart = nil
            edgeHoverDirection = 0
            return 0
        }
        if edgeHoverDirection != direction {
            edgeHoverDirection = direction
            edgeHoverStart = now
            return 0
        }
        guard let start = edgeHoverStart else { return 0 }
        if now.timeIntervalSince(start) >= Self.edgeHoverDelay {
            edgeHoverStart = now
            return direction
        }
        return 0
    }

    /// 落位：有落点时返回占位信息；无落点时返回 nil，调用方做 0.45s 飞回。
    func drop() -> (page: Int, index: Int)? {
        defer { reset() }
        guard isDragging, hasValidDropTarget else { return nil }
        return (placeholderPage, placeholderIndex)
    }

    /// 无落点飞回：调用方用 flyBackDuration 做动画回到原格，本方法只清状态。
    func flyBack() {
        reset()
    }

    func cancel() {
        reset()
    }

    private func reset() {
        draggedBundleID = nil
        isDragging = false
        isLongPressArmed = false
        hasValidDropTarget = false
        edgeHoverStart = nil
        edgeHoverDirection = 0
    }
}
