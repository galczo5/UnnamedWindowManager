import AppKit

// Manages ScrollingRootSlot creation and mutation in SharedRootStore.
final class ScrollingTileService {
    static let shared = ScrollingTileService()
    private init() {}

    private let store    = SharedRootStore.shared
    private let position = ScrollingPositionService()

    func snapshotVisibleScrollingRoot() -> ScrollingRootSlot? {
        Logger.shared.log("snapshotVisibleScrollingRoot")
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
        Logger.shared.log("isTracked: hash=\(key.windowHash)")
        return store.queue.sync {
            store.roots.values.contains { rootSlot in
                guard case .scrolling(let root) = rootSlot else { return false }
                return containsWindow(key, in: root)
            }
        }
    }

    func createScrollingRoot(key: WindowSlot, screen: NSScreen) {
        Logger.shared.log("createScrollingRoot: hash=\(key.windowHash)")
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
        Logger.shared.log("addWindow: hash=\(key.windowHash)")
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else {
                Logger.shared.log("addWindow: no visible scrolling root, skipping")
                return
            }
            guard !containsWindow(key, in: root) else {
                Logger.shared.log("addWindow: already tracked, skipping")
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

    /// Scrolls right: first child of right slot becomes center, old center appended to left slot.
    /// Returns the new center WindowSlot, or nil if right slot is empty.
    func scrollRight(screen: NSScreen) -> WindowSlot? {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else { return nil }
            guard case .stacking(var rightStack) = root.right else { return nil }

            let newCenterWin = rightStack.children.removeFirst()
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

    /// Scrolls left: last child of left slot becomes center, old center inserted at front of right slot.
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
                    s.children.insert(oldCenter, at: 0)
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

    // MARK: - Private

    /// Must be called inside a `store.queue` block.
    private func visibleScrollingRootID() -> UUID? {
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let cgList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        var visibleHashes = Set<UInt>()
        for info in cgList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid  = info[kCGWindowOwnerPID as String] as? Int,
                  let wid  = info[kCGWindowNumber as String] as? CGWindowID,
                  pid_t(pid) != ownPID else { continue }
            visibleHashes.insert(UInt(wid))
        }

        for (id, rootSlot) in store.roots {
            guard case .scrolling(let root) = rootSlot else { continue }
            if windowHashes(in: root).contains(where: { visibleHashes.contains($0) }) { return id }
        }
        return nil
    }

    private func containsWindow(_ key: WindowSlot, in root: ScrollingRootSlot) -> Bool {
        windowHashes(in: root).contains(key.windowHash)
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
