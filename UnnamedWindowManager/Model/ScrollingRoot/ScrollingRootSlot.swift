import AppKit

// The root of a scrolling layout: a center slot flanked by optional left and right slots.
// Contains all query, mutation, and sizing operations on the scrolling tree.
struct ScrollingRootSlot {
    var id: UUID
    var size: CGSize
    // User-set fraction of screen width for the center slot. nil = use Config.scrollCenterDefaultWidthFraction.
    var centerWidthFraction: CGFloat? = nil
    var left: Slot?
    var center: Slot
    var right: Slot?

    // MARK: - Query

    func containsWindow(_ key: WindowSlot) -> Bool {
        allWindowSlots().contains { $0.windowHash == key.windowHash }
    }

    func isCenterWindow(_ key: WindowSlot) -> Bool {
        switch center {
        case .window(let w):   return w.windowHash == key.windowHash
        case .stacking(let s): return s.children.contains { $0.windowHash == key.windowHash }
        default:               return false
        }
    }

    func allWindowSlots() -> [WindowSlot] {
        var slots: [WindowSlot] = []
        func collect(_ slot: Slot) {
            switch slot {
            case .window(let w):    slots.append(w)
            case .stacking(let s): slots.append(contentsOf: s.children)
            default: break
            }
        }
        if let left  { collect(left) }
        collect(center)
        if let right { collect(right) }
        return slots
    }

    func location(of key: WindowSlot) -> ScrollingSlotLocation? {
        if isCenterWindow(key) { return .center }
        if case .stacking(let s) = left,
           let idx = s.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
            return .left(index: idx, count: s.children.count)
        }
        if case .stacking(let s) = right,
           let idx = s.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
            return .right(index: idx, count: s.children.count)
        }
        return nil
    }

    // MARK: - Mutation

    // Takes a fully pre-constructed WindowSlot (caller sets id, parentId, order).
    mutating func addWindow(_ slot: WindowSlot, screenArea: CGSize) {
        if case .window(let oldCenter) = center {
            Self.appendToSide(oldCenter, side: &left, align: .right, parentId: id)
        }
        center = .window(slot)
        if let preTileSize = slot.preTileSize, preTileSize.width > 0 {
            centerWidthFraction = Self.clampedCenterFraction(
                proposedWidth: preTileSize.width, screenWidth: screenArea.width)
        }
    }

    /// Returns the new center WindowSlot, or nil if right side is empty.
    mutating func scrollRight(screenArea: CGSize) -> WindowSlot? {
        guard case .stacking(var rightStack) = right else { return nil }
        let newCenterWin = rightStack.children.removeLast()
        right = rightStack.children.isEmpty ? nil : .stacking(rightStack)
        if case .window(let oldCenter) = center {
            Self.appendToSide(oldCenter, side: &left, align: .right, parentId: id)
        }
        center = .window(newCenterWin)
        if newCenterWin.size.width > 0 {
            centerWidthFraction = Self.clampedCenterFraction(
                proposedWidth: newCenterWin.size.width, screenWidth: screenArea.width)
        }
        return newCenterWin
    }

    /// Returns the new center WindowSlot, or nil if left side is empty.
    mutating func scrollLeft(screenArea: CGSize) -> WindowSlot? {
        guard case .stacking(var leftStack) = left else { return nil }
        let newCenterWin = leftStack.children.removeLast()
        left = leftStack.children.isEmpty ? nil : .stacking(leftStack)
        if case .window(let oldCenter) = center {
            Self.appendToSide(oldCenter, side: &right, align: .left, parentId: id)
        }
        center = .window(newCenterWin)
        if newCenterWin.size.width > 0 {
            centerWidthFraction = Self.clampedCenterFraction(
                proposedWidth: newCenterWin.size.width, screenWidth: screenArea.width)
        }
        return newCenterWin
    }

    /// Removes a window from any zone. Returns (removed, rootExhausted).
    /// rootExhausted is true when center had no sides to promote from — caller should delete the root.
    mutating func removeWindow(_ key: WindowSlot) -> (removed: WindowSlot?, rootExhausted: Bool) {
        if case .window(let c) = center, c.windowHash == key.windowHash {
            if case .stacking(var leftStack) = left {
                let promoted = leftStack.children.removeLast()
                left = leftStack.children.isEmpty ? nil : .stacking(leftStack)
                center = .window(promoted)
            } else if case .stacking(var rightStack) = right {
                let promoted = rightStack.children.removeLast()
                right = rightStack.children.isEmpty ? nil : .stacking(rightStack)
                center = .window(promoted)
            } else {
                return (c, true)
            }
            return (c, false)
        }
        if case .stacking(var leftStack) = left,
           let idx = leftStack.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
            let removed = leftStack.children.remove(at: idx)
            left = leftStack.children.isEmpty ? nil : .stacking(leftStack)
            return (removed, false)
        }
        if case .stacking(var rightStack) = right,
           let idx = rightStack.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
            let removed = rightStack.children.remove(at: idx)
            right = rightStack.children.isEmpty ? nil : .stacking(rightStack)
            return (removed, false)
        }
        return (nil, false)
    }

    /// Batch-scrolls so that `key` becomes center. Returns the new center, or nil if already center / not found.
    mutating func scrollToWindow(_ key: WindowSlot, screenArea: CGSize) -> WindowSlot? {
        guard let loc = location(of: key) else { return nil }
        guard case .window(let oldCenter) = center else { return nil }
        let target: WindowSlot
        switch loc {
        case .center:
            return nil
        case .right(let index, _):
            guard case .stacking(var stack) = right else { return nil }
            let removed = Array(stack.children[index...])
            stack.children.removeSubrange(index...)
            right = stack.children.isEmpty ? nil : .stacking(stack)
            Self.appendToSide(oldCenter, side: &left, align: .right, parentId: id)
            for win in removed.dropFirst().reversed() {
                Self.appendToSide(win, side: &left, align: .right, parentId: id)
            }
            target = removed.first!
        case .left(let index, _):
            guard case .stacking(var stack) = left else { return nil }
            let removed = Array(stack.children[index...])
            stack.children.removeSubrange(index...)
            left = stack.children.isEmpty ? nil : .stacking(stack)
            Self.appendToSide(oldCenter, side: &right, align: .left, parentId: id)
            for win in removed.dropFirst().reversed() {
                Self.appendToSide(win, side: &right, align: .left, parentId: id)
            }
            target = removed.first!
        }
        center = .window(target)
        if target.size.width > 0 {
            centerWidthFraction = Self.clampedCenterFraction(
                proposedWidth: target.size.width, screenWidth: screenArea.width)
        }
        return target
    }

    /// Moves the last window of the given side to the opposite side. Returns the moved window, or nil if no swap occurred.
    mutating func swapWindows(_ direction: FocusDirection) -> WindowSlot? {
        switch direction {
        case .left:
            guard case .stacking(var leftStack) = left else { return nil }
            let moved = leftStack.children.removeLast()
            left = leftStack.children.isEmpty ? nil : .stacking(leftStack)
            Self.appendToSide(moved, side: &right, align: .left, parentId: id)
            return moved
        case .right:
            guard case .stacking(var rightStack) = right else { return nil }
            let moved = rightStack.children.removeLast()
            right = rightStack.children.isEmpty ? nil : .stacking(rightStack)
            Self.appendToSide(moved, side: &left, align: .right, parentId: id)
            return moved
        case .up, .down:
            return nil
        }
    }

    mutating func updateCenterFraction(proposedWidth: CGFloat, screenWidth: CGFloat) {
        centerWidthFraction = Self.clampedCenterFraction(proposedWidth: proposedWidth, screenWidth: screenWidth)
    }

    // MARK: - Sizing

    // When updateSideWindowWidths is false, only slot boundaries are updated for side slots —
    // window widths inside them are left unchanged. Used during center-only resize so side windows
    // keep their rendered size while their position is still recalculated correctly.
    mutating func recomputeSizes(width: CGFloat, height: CGFloat, updateSideWindowWidths: Bool = true) {
        size = CGSize(width: width, height: height)
        let fraction    = centerWidthFraction ?? Config.scrollCenterDefaultWidthFraction
        let centerWidth = (width * fraction).rounded()
        let remaining   = width - centerWidth
        let bothSides   = left != nil && right != nil
        let sideWidth   = (bothSides ? remaining / 2 : remaining).rounded()

        if left  != nil { Self.setSideSizes(&left!,  slotWidth: sideWidth, windowWidth: updateSideWindowWidths ? centerWidth : nil, height: height) }
        Self.setSizes(&center,                        width: centerWidth, height: height)
        if right != nil { Self.setSideSizes(&right!, slotWidth: sideWidth, windowWidth: updateSideWindowWidths ? centerWidth : nil, height: height) }
    }

    // Clamps a proposed center pixel width to [scrollCenterMinWidthFraction, scrollCenterMaxWidthFraction] of screenWidth.
    static func clampedCenterFraction(proposedWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {
        let minWidth = (screenWidth * Config.scrollCenterMinWidthFraction).rounded()
        let maxWidth = (screenWidth * Config.scrollCenterMaxWidthFraction).rounded()
        return min(maxWidth, max(minWidth, proposedWidth)) / screenWidth
    }

    // MARK: - Private

    // Appends `window` into a side stacking slot, creating one if the side is nil.
    private static func appendToSide(_ window: WindowSlot, side: inout Slot?, align: StackingAlign, parentId: UUID) {
        switch side {
        case nil:
            side = .stacking(StackingSlot(id: UUID(), parentId: parentId,
                                          size: .zero, children: [window], align: align))
        case .stacking(var s):
            s.children.append(window)
            side = .stacking(s)
        default:
            break
        }
    }

    // Sets the slot boundary to slotWidth and (if windowWidth is non-nil) each window inside to windowWidth.
    // Used for side zones where windows are wider than their slot (they peek behind center).
    private static func setSideSizes(_ slot: inout Slot, slotWidth: CGFloat, windowWidth: CGFloat?, height: CGFloat) {
        switch slot {
        case .window(var w):
            if let ww = windowWidth { w.size.width = ww }
            w.size.height = height
            slot = .window(w)
        case .stacking(var s):
            s.size = CGSize(width: slotWidth, height: height)
            if let ww = windowWidth {
                for i in s.children.indices { s.children[i].size = CGSize(width: ww, height: height) }
            }
            slot = .stacking(s)
        default:
            break
        }
    }

    private static func setSizes(_ slot: inout Slot, width: CGFloat, height: CGFloat) {
        switch slot {
        case .window(var w):
            w.size = CGSize(width: width, height: height)
            slot = .window(w)
        case .stacking(var s):
            s.size = CGSize(width: width, height: height)
            for i in s.children.indices { s.children[i].size = CGSize(width: width, height: height) }
            slot = .stacking(s)
        default:
            break
        }
    }
}
