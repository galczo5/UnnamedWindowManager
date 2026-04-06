import AppKit

// Manages ScrollingRootSlot creation and mutation in SharedRootStore.
// All tree logic lives on ScrollingRootSlot; this class handles locking, root lookup, and logging.
final class ScrollingRootStore {
    static let shared = ScrollingRootStore()
    private init() {}

    private let store = SharedRootStore.shared

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
            return root.allWindowSlots().map { .window($0) }
        }
    }

    func isTracked(_ key: WindowSlot) -> Bool {
        return store.queue.sync {
            store.roots.values.contains { rootSlot in
                guard case .scrolling(let root) = rootSlot else { return false }
                return root.containsWindow(key)
            }
        }
    }

    func scrollingRootInfo(containing key: WindowSlot) -> (rootID: UUID, centerHash: UInt)? {
        store.queue.sync {
            for (id, rootSlot) in store.roots {
                guard case .scrolling(let root) = rootSlot,
                      root.containsWindow(key) else { continue }
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
        var logID: UUID? = nil
        store.queue.sync(flags: .barrier) {
            let id   = UUID()
            let area = screenTilingArea(screen)
            let win  = WindowSlot(pid: key.pid, windowHash: key.windowHash,
                                  id: UUID(), parentId: id, order: 1,
                                  size: .zero, gaps: true,
                                  preTileOrigin: key.preTileOrigin, preTileSize: key.preTileSize)
            var root = ScrollingRootSlot(id: id, size: area,
                                         left: nil, center: .window(win), right: nil)
            if let preTileSize = key.preTileSize, preTileSize.width > 0 {
                root.centerWidthFraction = ScrollingRootSlot.clampedCenterFraction(
                    proposedWidth: preTileSize.width, screenWidth: area.width)
            }
            root.recomputeSizes(width: area.width, height: area.height)
            store.roots[id] = .scrolling(root)
            store.windowCounts[id] = 1
            logID = id
        }
        if let rootID = logID {
            WindowLister.logWindowEvent(action: "scrolled (new root)", windowHash: key.windowHash, rootID: rootID)
        }
    }

    func addWindow(_ key: WindowSlot, screen: NSScreen) {
        var logID: UUID? = nil
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else { return }
            guard !root.containsWindow(key) else { return }

            store.windowCounts[id, default: 0] += 1
            let order = store.windowCounts[id]!
            let newWin = WindowSlot(pid: key.pid, windowHash: key.windowHash,
                                    id: UUID(), parentId: id, order: order,
                                    size: .zero, gaps: true,
                                    preTileOrigin: key.preTileOrigin, preTileSize: key.preTileSize)
            let area = screenTilingArea(screen)
            root.addWindow(newWin, screenArea: area)
            root.recomputeSizes(width: area.width, height: area.height, updateSideWindowWidths: false)
            store.roots[id] = .scrolling(root)
            logID = id
        }
        if let rootID = logID {
            WindowLister.logWindowEvent(action: "scrolled (added)", windowHash: key.windowHash, rootID: rootID)
        }
    }

    /// Returns the new center WindowSlot, or nil if right slot is empty.
    func scrollRight(screen: NSScreen) -> WindowSlot? {
        var logInfo: (hash: UInt, rootID: UUID)? = nil
        let result: WindowSlot? = store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else { return nil }
            let area = screenTilingArea(screen)
            guard let newCenter = root.scrollRight(screenArea: area) else { return nil }
            root.recomputeSizes(width: area.width, height: area.height, updateSideWindowWidths: false)
            store.roots[id] = .scrolling(root)
            logInfo = (hash: newCenter.windowHash, rootID: id)
            return newCenter
        }
        if let info = logInfo {
            WindowLister.logWindowEvent(action: "scrolled right", windowHash: info.hash, rootID: info.rootID)
        }
        return result
    }

    /// Returns the new center WindowSlot, or nil if left slot is empty.
    func scrollLeft(screen: NSScreen) -> WindowSlot? {
        var logInfo: (hash: UInt, rootID: UUID)? = nil
        let result: WindowSlot? = store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else { return nil }
            let area = screenTilingArea(screen)
            guard let newCenter = root.scrollLeft(screenArea: area) else { return nil }
            root.recomputeSizes(width: area.width, height: area.height, updateSideWindowWidths: false)
            store.roots[id] = .scrolling(root)
            logInfo = (hash: newCenter.windowHash, rootID: id)
            return newCenter
        }
        if let info = logInfo {
            WindowLister.logWindowEvent(action: "scrolled left", windowHash: info.hash, rootID: info.rootID)
        }
        return result
    }

    func removeVisibleScrollingRoot() -> [WindowSlot] {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(let root) = store.roots[id] else { return [] }
            let slots = root.allWindowSlots()
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
                all += root.allWindowSlots()
                store.removeRoot(id: id)
            }
            return all
        }
    }

    /// Removes a single window from the scrolling root and reflows. Returns the stored WindowSlot, or nil if not found.
    func removeWindow(_ key: WindowSlot, screen: NSScreen) -> WindowSlot? {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else { return nil }
            let (removed, rootExhausted) = root.removeWindow(key)
            guard let removed else { return nil }
            if rootExhausted {
                store.removeRoot(id: id)
            } else {
                let area = screenTilingArea(screen)
                root.recomputeSizes(width: area.width, height: area.height, updateSideWindowWidths: false)
                store.roots[id] = .scrolling(root)
            }
            return removed
        }
    }

    func updateCenterFraction(for key: WindowSlot, proposedWidth: CGFloat, screenWidth: CGFloat, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else { return }
            guard root.isCenterWindow(key) else { return }
            root.updateCenterFraction(proposedWidth: proposedWidth, screenWidth: screenWidth)
            let area = screenTilingArea(screen)
            root.recomputeSizes(width: area.width, height: area.height, updateSideWindowWidths: false)
            store.roots[id] = .scrolling(root)
        }
    }

    func isCenterWindow(_ key: WindowSlot) -> Bool {
        store.queue.sync {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(let root) = store.roots[id] else { return false }
            return root.isCenterWindow(key)
        }
    }

    func location(of key: WindowSlot) -> ScrollingSlotLocation? {
        store.queue.sync {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(let root) = store.roots[id] else { return nil }
            return root.location(of: key)
        }
    }

    /// Batch-scrolls so that `key` becomes center. Returns the new center, or nil if already center / not found.
    func scrollToWindow(_ key: WindowSlot, screen: NSScreen) -> WindowSlot? {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else { return nil }
            let area = screenTilingArea(screen)
            guard let newCenter = root.scrollToWindow(key, screenArea: area) else { return nil }
            root.recomputeSizes(width: area.width, height: area.height, updateSideWindowWidths: false)
            store.roots[id] = .scrolling(root)
            return newCenter
        }
    }

    /// swapLeft: moves the last window of the left stacking slot to the end of the right stacking slot.
    /// swapRight: moves the last window of the right stacking slot to the end of the left stacking slot.
    @discardableResult
    func swapWindows(_ direction: FocusDirection, screen: NSScreen) -> WindowSlot? {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else { return nil }
            guard let moved = root.swapWindows(direction) else { return nil }
            let area = screenTilingArea(screen)
            root.recomputeSizes(width: area.width, height: area.height, updateSideWindowWidths: false)
            store.roots[id] = .scrolling(root)
            return moved
        }
    }

    // MARK: - Private

    private func visibleScrollingRootID() -> UUID? {
        let visibleHashes = OnScreenWindowCache.visibleHashes()
        for (id, rootSlot) in store.roots {
            guard case .scrolling(let root) = rootSlot else { continue }
            if root.allWindowSlots().contains(where: { visibleHashes.contains($0.windowHash) }) { return id }
        }
        return nil
    }
}
