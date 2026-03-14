import AppKit

// Manages ScrollingRootSlot creation and mutation in SharedRootStore.
final class ScrollingTileService {
    static let shared = ScrollingTileService()
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
            let id  = UUID()
            let og  = Config.outerGaps
            let w   = screen.visibleFrame.width  - og.left! - og.right!
            let h   = screen.visibleFrame.height - og.top!  - og.bottom!
            let win = WindowSlot(pid: key.pid, windowHash: key.windowHash,
                                 id: UUID(), parentId: id, order: 1,
                                 width: 0, height: 0, gaps: true,
                                 preTileOrigin: key.preTileOrigin, preTileSize: key.preTileSize)
            var root = ScrollingRootSlot(id: id, width: w, height: h,
                                         left: nil, center: .window(win), right: nil)
            position.recomputeSizes(&root, width: w, height: h)
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
                                    width: 0, height: 0, gaps: true,
                                    preTileOrigin: key.preTileOrigin, preTileSize: key.preTileSize)

            // Move old center into left StackingSlot, then put new window in center.
            if case .window(let oldCenter) = root.center {
                switch root.left {
                case nil:
                    let stacking = StackingSlot(id: UUID(), parentId: id,
                                                width: 0, height: 0,
                                                children: [oldCenter],
                                                align: .right)
                    root.left = .stacking(stacking)
                case .stacking(var s):
                    s.children.append(oldCenter)
                    root.left = .stacking(s)
                default:
                    break
                }
            }

            root.center = .window(newWin)
            let og = Config.outerGaps
            let w  = screen.visibleFrame.width  - og.left! - og.right!
            let h  = screen.visibleFrame.height - og.top!  - og.bottom!
            position.recomputeSizes(&root, width: w, height: h)
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
                switch root.left {
                case nil:
                    let s = StackingSlot(id: UUID(), parentId: id, width: 0, height: 0,
                                         children: [oldCenter], align: .right)
                    root.left = .stacking(s)
                case .stacking(var s):
                    s.children.append(oldCenter)
                    root.left = .stacking(s)
                default: break
                }
            }

            root.center = .window(newCenterWin)
            let og = Config.outerGaps
            let w  = screen.visibleFrame.width  - og.left! - og.right!
            let h  = screen.visibleFrame.height - og.top!  - og.bottom!
            position.recomputeSizes(&root, width: w, height: h)
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
                switch root.right {
                case nil:
                    let s = StackingSlot(id: UUID(), parentId: id, width: 0, height: 0,
                                         children: [oldCenter], align: .left)
                    root.right = .stacking(s)
                case .stacking(var s):
                    s.children.append(oldCenter)
                    root.right = .stacking(s)
                default: break
                }
            }

            root.center = .window(newCenterWin)
            let og = Config.outerGaps
            let w  = screen.visibleFrame.width  - og.left! - og.right!
            let h  = screen.visibleFrame.height - og.top!  - og.bottom!
            position.recomputeSizes(&root, width: w, height: h)
            store.roots[id] = .scrolling(root)
            return newCenterWin
        }
    }

    func removeVisibleScrollingRoot() -> [WindowSlot] {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(let root) = store.roots[id] else { return [] }
            let slots = allWindowSlots(in: root)
            store.roots.removeValue(forKey: id)
            store.windowCounts.removeValue(forKey: id)
            return slots
        }
    }

    func removeAllScrollingRoots() -> [WindowSlot] {
        return store.queue.sync(flags: .barrier) {
            let ids = store.roots.keys.filter { if case .scrolling = store.roots[$0]! { return true }; return false }
            var all: [WindowSlot] = []
            for id in ids {
                guard case .scrolling(let root) = store.roots[id] else { continue }
                all += allWindowSlots(in: root)
                store.roots.removeValue(forKey: id)
                store.windowCounts.removeValue(forKey: id)
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

            let og = Config.outerGaps
            let w  = screen.visibleFrame.width  - og.left! - og.right!
            let h  = screen.visibleFrame.height - og.top!  - og.bottom!

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
                    store.roots.removeValue(forKey: id)
                    store.windowCounts.removeValue(forKey: id)
                    return center
                }
                position.recomputeSizes(&root, width: w, height: h)
                store.roots[id] = .scrolling(root)
                return center
            }

            // Left stacking slot?
            if case .stacking(var leftStack) = root.left,
               let idx = leftStack.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
                let removed = leftStack.children.remove(at: idx)
                root.left = leftStack.children.isEmpty ? nil : .stacking(leftStack)
                position.recomputeSizes(&root, width: w, height: h)
                store.roots[id] = .scrolling(root)
                return removed
            }

            // Right stacking slot?
            if case .stacking(var rightStack) = root.right,
               let idx = rightStack.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
                let removed = rightStack.children.remove(at: idx)
                root.right = rightStack.children.isEmpty ? nil : .stacking(rightStack)
                position.recomputeSizes(&root, width: w, height: h)
                store.roots[id] = .scrolling(root)
                return removed
            }

            return nil
        }
    }

    // MARK: - Private

    /// Must be called inside a `store.queue` block.
    private func visibleScrollingRootID() -> UUID? {
        let visibleHashes = OnScreenWindowCache.visibleHashes()
        for (id, rootSlot) in store.roots {
            guard case .scrolling(let root) = rootSlot else { continue }
            if windowHashes(in: root).contains(where: { visibleHashes.contains($0) }) { return id }
        }
        return nil
    }

    private func containsWindow(_ key: WindowSlot, in root: ScrollingRootSlot) -> Bool {
        windowHashes(in: root).contains(key.windowHash)
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

    private func windowHashes(in root: ScrollingRootSlot) -> [UInt] {
        var hashes: [UInt] = []
        func collect(_ slot: Slot) {
            switch slot {
            case .window(let w):    hashes.append(w.windowHash)
            case .stacking(let s): s.children.forEach { hashes.append($0.windowHash) }
            default: break
            }
        }
        if let left  = root.left  { collect(left) }
        collect(root.center)
        if let right = root.right { collect(right) }
        return hashes
    }
}
