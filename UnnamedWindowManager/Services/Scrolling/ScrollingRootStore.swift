import AppKit

// Which slot a window occupies in a scrolling root.
enum ScrollingSlotLocation {
    case center
    case left(index: Int, count: Int)
    case right(index: Int, count: Int)
}

// Manages ScrollingRootSlot creation and mutation in SharedRootStore.
final class ScrollingRootStore {
    static let shared = ScrollingRootStore()
    private init() {}

    private let store    = SharedRootStore.shared
    private let position = ScrollingPositionService()

    func snapshotVisibleScrollingRoot() -> ScrollingRootSlot? {
        return store.queue.sync {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(let root) = store.roots[id] else { return nil }
            return root
        }
    }

    func leavesInVisibleScrollingRoot() -> [Slot] {
        store.queue.sync {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(let root) = store.roots[id] else { return [] }
            var leaves: [Slot] = []
            func collect(_ slot: Slot) {
                switch slot {
                case .window:          leaves.append(slot)
                case .stacking(let s): leaves.append(contentsOf: s.children.map { .window($0) })
                default: break
                }
            }
            if let left  = root.left  { collect(left) }
            collect(root.center)
            if let right = root.right { collect(right) }
            return leaves
        }
    }

    func isTracked(_ key: WindowSlot) -> Bool {
        return store.queue.sync {
            store.roots.values.contains { rootSlot in
                guard case .scrolling(let root) = rootSlot else { return false }
                return containsWindow(key, in: root)
            }
        }
    }

    func scrollingRootInfo(containing key: WindowSlot) -> (rootID: UUID, centerHash: UInt)? {
        store.queue.sync {
            for (id, rootSlot) in store.roots {
                guard case .scrolling(let root) = rootSlot,
                      containsWindow(key, in: root) else { continue }
                switch root.center {
                case .window(let w):   return (id, w.windowHash)
                case .stacking(let s): return s.children.first.map { (id, $0.windowHash) }
                default:               return nil
                }
            }
            return nil
        }
    }

    func createScrollingRoot(key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            let id   = UUID()
            let area = screenTilingArea(screen)
            let win  = WindowSlot(pid: key.pid, windowHash: key.windowHash,
                                  id: UUID(), parentId: id, order: 1,
                                  size: .zero, gaps: true,
                                  preTileOrigin: key.preTileOrigin, preTileSize: key.preTileSize)
            var root = ScrollingRootSlot(id: id, size: area,
                                         left: nil, center: .window(win), right: nil)
            position.recomputeSizes(&root, width: area.width, height: area.height)
            store.roots[id] = .scrolling(root)
            store.windowCounts[id] = 1
        }
    }

    func addWindow(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else {
                return
            }
            guard !containsWindow(key, in: root) else {
                return
            }

            store.windowCounts[id, default: 0] += 1
            let order = store.windowCounts[id]!
            let newWin = WindowSlot(pid: key.pid, windowHash: key.windowHash,
                                    id: UUID(), parentId: id, order: order,
                                    size: .zero, gaps: true,
                                    preTileOrigin: key.preTileOrigin, preTileSize: key.preTileSize)

            // Move old center into left StackingSlot, then put new window in center.
            if case .window(let oldCenter) = root.center {
                appendToSide(oldCenter, side: &root.left, parentId: id, align: .right)
            }

            root.center = .window(newWin)
            let area = screenTilingArea(screen)
            position.recomputeSizes(&root, width: area.width, height: area.height)
            store.roots[id] = .scrolling(root)
        }
    }

    /// Scrolls right: last child of right slot becomes center, old center appended to left slot.
    /// Returns the new center WindowSlot, or nil if right slot is empty.
    func scrollRight(screen: NSScreen) -> WindowSlot? {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else { return nil }
            guard case .stacking(var rightStack) = root.right else { return nil }

            let newCenterWin = rightStack.children.removeLast()
            root.right = rightStack.children.isEmpty ? nil : .stacking(rightStack)

            if case .window(let oldCenter) = root.center {
                appendToSide(oldCenter, side: &root.left, parentId: id, align: .right)
            }

            root.center = .window(newCenterWin)
            let area = screenTilingArea(screen)
            if newCenterWin.size.width > 0 {
                root.centerWidthFraction = ScrollingPositionService.clampedCenterFraction(
                    proposedWidth: newCenterWin.size.width, screenWidth: area.width)
            }
            position.recomputeSizes(&root, width: area.width, height: area.height, updateSideWindowWidths: false)
            store.roots[id] = .scrolling(root)
            return newCenterWin
        }
    }

    /// Scrolls left: last child of left slot becomes center, old center appended to right slot.
    /// Returns the new center WindowSlot, or nil if left slot is empty.
    func scrollLeft(screen: NSScreen) -> WindowSlot? {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else { return nil }
            guard case .stacking(var leftStack) = root.left else { return nil }

            let newCenterWin = leftStack.children.removeLast()
            root.left = leftStack.children.isEmpty ? nil : .stacking(leftStack)

            if case .window(let oldCenter) = root.center {
                appendToSide(oldCenter, side: &root.right, parentId: id, align: .left)
            }

            root.center = .window(newCenterWin)
            let area = screenTilingArea(screen)
            if newCenterWin.size.width > 0 {
                root.centerWidthFraction = ScrollingPositionService.clampedCenterFraction(
                    proposedWidth: newCenterWin.size.width, screenWidth: area.width)
            }
            position.recomputeSizes(&root, width: area.width, height: area.height, updateSideWindowWidths: false)
            store.roots[id] = .scrolling(root)
            return newCenterWin
        }
    }

    func removeVisibleScrollingRoot() -> [WindowSlot] {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(let root) = store.roots[id] else { return [] }
            let slots = allWindowSlots(in: root)
            store.removeRoot(id: id)
            return slots
        }
    }

    func removeAllScrollingRoots() -> [WindowSlot] {
        return store.queue.sync(flags: .barrier) {
            let ids = store.roots.keys.filter { id in
                guard case .scrolling = store.roots[id] else { return false }
                return true
            }
            var all: [WindowSlot] = []
            for id in ids {
                guard case .scrolling(let root) = store.roots[id] else { continue }
                all += allWindowSlots(in: root)
                store.removeRoot(id: id)
            }
            return all
        }
    }

    /// Removes a single window from the scrolling root and reflows. If the removed window
    /// was the center, promotes the last child of the left stacking slot (or right if left empty).
    /// Returns the stored WindowSlot (with preTileOrigin/preTileSize), or nil if not found.
    func removeWindow(_ key: WindowSlot, screen: NSScreen) -> WindowSlot? {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else { return nil }

            let area = screenTilingArea(screen)

            // Center?
            if case .window(let center) = root.center, center.windowHash == key.windowHash {
                if case .stacking(var leftStack) = root.left {
                    let promoted = leftStack.children.removeLast()
                    root.left    = leftStack.children.isEmpty ? nil : .stacking(leftStack)
                    root.center  = .window(promoted)
                } else if case .stacking(var rightStack) = root.right {
                    let promoted = rightStack.children.removeLast()
                    root.right   = rightStack.children.isEmpty ? nil : .stacking(rightStack)
                    root.center  = .window(promoted)
                } else {
                    store.removeRoot(id: id)
                    return center
                }
                position.recomputeSizes(&root, width: area.width, height: area.height)
                store.roots[id] = .scrolling(root)
                return center
            }

            // Left stacking slot?
            if case .stacking(var leftStack) = root.left,
               let idx = leftStack.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
                let removed = leftStack.children.remove(at: idx)
                root.left = leftStack.children.isEmpty ? nil : .stacking(leftStack)
                position.recomputeSizes(&root, width: area.width, height: area.height)
                store.roots[id] = .scrolling(root)
                return removed
            }

            // Right stacking slot?
            if case .stacking(var rightStack) = root.right,
               let idx = rightStack.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
                let removed = rightStack.children.remove(at: idx)
                root.right = rightStack.children.isEmpty ? nil : .stacking(rightStack)
                position.recomputeSizes(&root, width: area.width, height: area.height)
                store.roots[id] = .scrolling(root)
                return removed
            }

            return nil
        }
    }

    func updateCenterFraction(for key: WindowSlot, proposedWidth: CGFloat, screenWidth: CGFloat, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else { return }
            guard isCenterWindow(key, in: root) else { return }

            let fraction = ScrollingPositionService.clampedCenterFraction(
                proposedWidth: proposedWidth,
                screenWidth: screenWidth
            )
            root.centerWidthFraction = fraction
            let area = screenTilingArea(screen)
            position.recomputeSizes(&root, width: screenWidth, height: area.height, updateSideWindowWidths: false)
            store.roots[id] = .scrolling(root)
        }
    }

    func isCenterWindow(_ key: WindowSlot) -> Bool {
        store.queue.sync {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(let root) = store.roots[id] else { return false }
            return isCenterWindow(key, in: root)
        }
    }

    func location(of key: WindowSlot) -> ScrollingSlotLocation? {
        store.queue.sync {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(let root) = store.roots[id] else { return nil }
            return location(of: key, in: root)
        }
    }

    /// Batch-scrolls so that `key` becomes center. Returns the new center WindowSlot, or nil if already center / not found.
    func scrollToWindow(_ key: WindowSlot, screen: NSScreen) -> WindowSlot? {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else { return nil }
            guard let location = location(of: key, in: root) else { return nil }
            guard case .window(let oldCenter) = root.center else { return nil }

            let target: WindowSlot
            switch location {
            case .center:
                return nil

            case .right(let index, _):
                guard case .stacking(var stack) = root.right else { return nil }
                let removed = Array(stack.children[index...])
                stack.children.removeSubrange(index...)
                root.right = stack.children.isEmpty ? nil : .stacking(stack)

                appendToSide(oldCenter, side: &root.left, parentId: id, align: .right)
                for win in removed.dropFirst().reversed() {
                    appendToSide(win, side: &root.left, parentId: id, align: .right)
                }
                target = removed.first!

            case .left(let index, _):
                guard case .stacking(var stack) = root.left else { return nil }
                let removed = Array(stack.children[index...])
                stack.children.removeSubrange(index...)
                root.left = stack.children.isEmpty ? nil : .stacking(stack)

                appendToSide(oldCenter, side: &root.right, parentId: id, align: .left)
                for win in removed.dropFirst().reversed() {
                    appendToSide(win, side: &root.right, parentId: id, align: .left)
                }
                target = removed.first!
            }

            root.center = .window(target)
            let area = screenTilingArea(screen)
            if target.size.width > 0 {
                root.centerWidthFraction = ScrollingPositionService.clampedCenterFraction(
                    proposedWidth: target.size.width, screenWidth: area.width)
            }
            position.recomputeSizes(&root, width: area.width, height: area.height,
                                    updateSideWindowWidths: false)
            store.roots[id] = .scrolling(root)
            return target
        }
    }

    /// swapLeft: moves the last window of the left stacking slot to the end of the right stacking slot.
    /// swapRight: moves the last window of the right stacking slot to the end of the left stacking slot.
    /// The center window and all slot sizes are untouched. Returns the moved window, or nil if no swap occurred.
    @discardableResult
    func swapWindows(_ direction: FocusDirection, screen: NSScreen) -> WindowSlot? {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else { return nil }

            let moved: WindowSlot
            switch direction {
            case .left:
                guard case .stacking(var leftStack) = root.left else { return nil }
                moved = leftStack.children.removeLast()
                root.left = leftStack.children.isEmpty ? nil : .stacking(leftStack)
                appendToSide(moved, side: &root.right, parentId: id, align: .left)
            case .right:
                guard case .stacking(var rightStack) = root.right else { return nil }
                moved = rightStack.children.removeLast()
                root.right = rightStack.children.isEmpty ? nil : .stacking(rightStack)
                appendToSide(moved, side: &root.left, parentId: id, align: .right)
            case .up, .down:
                return nil
            }

            let area = screenTilingArea(screen)
            position.recomputeSizes(&root, width: area.width, height: area.height, updateSideWindowWidths: false)
            store.roots[id] = .scrolling(root)
            return moved
        }
    }

    // MARK: - Private

    /// Appends `window` into a side stacking slot, creating one if the side is nil.
    private func appendToSide(_ window: WindowSlot, side: inout Slot?,
                              parentId: UUID, align: StackingAlign) {
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

    /// Must be called inside a `store.queue` block.
    private func visibleScrollingRootID() -> UUID? {
        let visibleHashes = OnScreenWindowCache.visibleHashes()
        for (id, rootSlot) in store.roots {
            guard case .scrolling(let root) = rootSlot else { continue }
            if allWindowSlots(in: root).contains(where: { visibleHashes.contains($0.windowHash) }) { return id }
        }
        return nil
    }

    private func location(of key: WindowSlot, in root: ScrollingRootSlot) -> ScrollingSlotLocation? {
        if isCenterWindow(key, in: root) { return .center }
        if case .stacking(let s) = root.left,
           let idx = s.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
            return .left(index: idx, count: s.children.count)
        }
        if case .stacking(let s) = root.right,
           let idx = s.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
            return .right(index: idx, count: s.children.count)
        }
        return nil
    }

    private func containsWindow(_ key: WindowSlot, in root: ScrollingRootSlot) -> Bool {
        allWindowSlots(in: root).contains { $0.windowHash == key.windowHash }
    }

    private func isCenterWindow(_ key: WindowSlot, in root: ScrollingRootSlot) -> Bool {
        switch root.center {
        case .window(let w):   return w.windowHash == key.windowHash
        case .stacking(let s): return s.children.contains { $0.windowHash == key.windowHash }
        default:               return false
        }
    }

    private func allWindowSlots(in root: ScrollingRootSlot) -> [WindowSlot] {
        var slots: [WindowSlot] = []
        func collect(_ slot: Slot) {
            switch slot {
            case .window(let w):    slots.append(w)
            case .stacking(let s): slots.append(contentsOf: s.children)
            default: break
            }
        }
        if let left  = root.left  { collect(left) }
        collect(root.center)
        if let right = root.right { collect(right) }
        return slots
    }
}
