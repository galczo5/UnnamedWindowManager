import AppKit

// Unified service for all tiling store operations: snapping windows in/out and structural edits.
// Each method acquires the store lock, delegates tree logic to TilingRootSlot, then writes back.
final class TilingService {
    static let shared = TilingService()
    private init() {}

    private let store     = SharedRootStore.shared
    private let rootStore = TilingRootStore.shared

    // MARK: - Snap

    /// Tiles `key` into the correct root, creating one if no tiled window is visible on screen.
    /// Idempotent: no-op if the window is already in the correct root.
    /// Performs a cross-root migration if the window belongs to a different root.
    func snap(_ key: WindowSlot, screen: NSScreen) {
        var snapRootID: UUID? = nil
        store.queue.sync(flags: .barrier) {
            let targetRootID: UUID
            if let visibleID = rootStore.visibleRootID() {
                targetRootID = visibleID
            } else {
                let id = UUID()
                let f  = screen.visibleFrame
                store.roots[id] = .tiling(TilingRootSlot(id: id, size: f.size,
                                                         orientation: .horizontal, children: []))
                targetRootID = id
            }

            guard case .tiling(var targetRoot) = store.roots[targetRootID] else { return }
            if targetRoot.isTracked(key) { return }

            var preTileOrigin = key.preTileOrigin
            var preTileSize = key.preTileSize
            if let srcID = rootStore.rootIDSync(containing: key),
               case .tiling(var srcRoot) = store.roots[srcID] {
                if let oldSlot = srcRoot.findLeaf(key), case .window(let oldWindow) = oldSlot {
                    preTileOrigin = oldWindow.preTileOrigin
                    preTileSize = oldWindow.preTileSize
                }
                srcRoot.removeLeaf(key)
                if srcRoot.children.isEmpty {
                    store.removeRoot(id: srcID)
                } else {
                    store.roots[srcID] = .tiling(srcRoot)
                }
            }

            store.windowCounts[targetRootID, default: 0] += 1
            let order = store.windowCounts[targetRootID]!
            let newLeaf = Slot.window(WindowSlot(
                pid: key.pid, windowHash: key.windowHash,
                id: UUID(), parentId: targetRoot.id,
                order: order, size: .zero, gaps: true,
                preTileOrigin: preTileOrigin, preTileSize: preTileSize
            ))
            if targetRoot.children.isEmpty {
                targetRoot.children = [newLeaf]
            } else {
                let lastOrder = targetRoot.maxLeafOrder()
                let orientation: Orientation = order % 2 == 0 ? .horizontal : .vertical
                targetRoot.extractAndWrap(targetOrder: lastOrder, newLeaf: newLeaf,
                                          orientation: orientation)
            }
            let area = screenTilingArea(screen)
            targetRoot.recomputeSizes(width: area.width, height: area.height)
            store.roots[targetRootID] = .tiling(targetRoot)
            snapRootID = targetRootID
        }
        if let rootID = snapRootID {
            DebugLogger.logWindowEvent(action: "tiled", windowHash: key.windowHash, rootID: rootID)
        }
    }

    func remove(_ key: WindowSlot) {
        store.queue.async(flags: .barrier) {
            guard let id = self.rootStore.rootIDSync(containing: key),
                  case .tiling(var root) = self.store.roots[id] else { return }
            root.removeLeaf(key)
            if root.children.isEmpty {
                self.store.removeRoot(id: id)
            } else {
                self.store.roots[id] = .tiling(root)
            }
        }
    }

    func removeAndReflow(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootStore.rootIDSync(containing: key),
                  case .tiling(var root) = store.roots[id] else { return }
            root.removeLeaf(key)
            if root.children.isEmpty {
                store.removeRoot(id: id)
            } else {
                let area = screenTilingArea(screen)
                root.recomputeSizes(width: area.width, height: area.height)
                store.roots[id] = .tiling(root)
            }
        }
    }

    func removeVisibleRoot() -> [WindowSlot] {
        return store.queue.sync(flags: .barrier) {
            guard let id = rootStore.visibleRootID(),
                  case .tiling(let root) = store.roots[id] else { return [] }
            let leaves = root.allLeaves()
            store.removeRoot(id: id)
            return leaves.compactMap { if case .window(let w) = $0 { return w } else { return nil } }
        }
    }

    func removeAllTilingRoots() -> [WindowSlot] {
        return store.queue.sync(flags: .barrier) {
            let ids = store.roots.keys.filter { id in
                guard case .tiling = store.roots[id] else { return false }
                return true
            }
            var all: [WindowSlot] = []
            for id in ids {
                guard case .tiling(let root) = store.roots[id] else { continue }
                all += root.allLeaves().compactMap { if case .window(let w) = $0 { return w } else { return nil } }
                store.removeRoot(id: id)
            }
            return all
        }
    }

    /// Merges all tiling roots that have windows visible on screen into a single root.
    func consolidateVisibleRoots(screen: NSScreen) {
        var mergedRootID: UUID? = nil
        store.queue.sync(flags: .barrier) {
            let onScreen = WindowOnScreenCache.visibleSet()

            let visiblePairs: [(id: UUID, root: TilingRootSlot)] = store.roots.compactMap { id, slot in
                guard case .tiling(let root) = slot else { return nil }
                let hasVisible = root.allLeaves().contains {
                    guard case .window(let w) = $0 else { return false }
                    return onScreen.contains(pid: w.pid, hash: w.windowHash)
                }
                return hasVisible ? (id, root) : nil
            }

            guard visiblePairs.count > 1 else { return }

            let (targetID, _) = visiblePairs.max { $0.root.allLeaves().count < $1.root.allLeaves().count }!
            guard case .tiling(var targetRoot) = store.roots[targetID] else { return }

            for (srcID, srcRoot) in visiblePairs where srcID != targetID {
                let leaves = srcRoot.allLeaves().compactMap { leaf -> WindowSlot? in
                    guard case .window(let w) = leaf else { return nil }
                    return w
                }
                for w in leaves {
                    store.windowCounts[targetID, default: 0] += 1
                    let order = store.windowCounts[targetID]!
                    let newLeaf = Slot.window(WindowSlot(
                        pid: w.pid, windowHash: w.windowHash,
                        id: UUID(), parentId: targetRoot.id,
                        order: order, size: .zero, gaps: true,
                        preTileOrigin: w.preTileOrigin, preTileSize: w.preTileSize
                    ))
                    if targetRoot.children.isEmpty {
                        targetRoot.children = [newLeaf]
                    } else {
                        let lastOrder = targetRoot.maxLeafOrder()
                        let orientation: Orientation = order % 2 == 0 ? .horizontal : .vertical
                        targetRoot.extractAndWrap(targetOrder: lastOrder, newLeaf: newLeaf,
                                                  orientation: orientation)
                    }
                }
                store.removeRoot(id: srcID)
            }

            let area = screenTilingArea(screen)
            targetRoot.recomputeSizes(width: area.width, height: area.height)
            store.roots[targetID] = .tiling(targetRoot)
            mergedRootID = targetID
        }
        if let rootID = mergedRootID {
            DebugLogger.logWindowEvent(action: "consolidated roots", windowHash: 0, rootID: rootID)
        }
    }

    // MARK: - Edit

    func resize(key: WindowSlot, actualSize: CGSize, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootStore.rootIDSync(containing: key),
                  case .tiling(var root) = store.roots[id] else { return }
            root.applyResize(key: key, actualSize: actualSize)
            let area = screenTilingArea(screen)
            root.recomputeSizes(width: area.width, height: area.height)
            store.roots[id] = .tiling(root)
        }
    }

    func swap(_ keyA: WindowSlot, _ keyB: WindowSlot) {
        guard keyA != keyB else { return }
        store.queue.sync(flags: .barrier) {
            guard let id = rootStore.rootIDSync(containing: keyA),
                  case .tiling(var root) = store.roots[id],
                  root.isTracked(keyB) else { return }
            let resolvedA: WindowSlot
            if let s = root.findLeaf(keyA), case .window(let w) = s { resolvedA = w } else { resolvedA = keyA }
            let resolvedB: WindowSlot
            if let s = root.findLeaf(keyB), case .window(let w) = s { resolvedB = w } else { resolvedB = keyB }
            root.swap(resolvedA, resolvedB)
            store.roots[id] = .tiling(root)
        }
    }

    func recomputeVisibleRootSizes(screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootStore.visibleRootID(),
                  case .tiling(var root) = store.roots[id] else { return }
            let area = screenTilingArea(screen)
            root.recomputeSizes(width: area.width, height: area.height)
            store.roots[id] = .tiling(root)
        }
    }

    func flipParentOrientation(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootStore.rootIDSync(containing: key),
                  case .tiling(var root) = store.roots[id] else { return }
            root.flipParentOrientation(of: key)
            let area = screenTilingArea(screen)
            root.recomputeSizes(width: area.width, height: area.height)
            store.roots[id] = .tiling(root)
        }
    }

    func insertAdjacent(dragged: WindowSlot, target: WindowSlot,
                        zone: DropZone, screen: NSScreen) {
        guard dragged != target else { return }
        store.queue.sync(flags: .barrier) {
            guard let draggedRootID = rootStore.rootIDSync(containing: dragged),
                  let targetRootID  = rootStore.rootIDSync(containing: target),
                  case .tiling(var draggedRoot) = store.roots[draggedRootID],
                  case .tiling(var targetRoot)  = store.roots[targetRootID],
                  let draggedSlot = draggedRoot.findLeaf(dragged),
                  case .window(let draggedWindow) = draggedSlot else { return }

            if draggedRootID == targetRootID {
                targetRoot.removeLeaf(dragged)
            } else {
                draggedRoot.removeLeaf(dragged)
                if draggedRoot.children.isEmpty {
                    store.removeRoot(id: draggedRootID)
                } else {
                    store.roots[draggedRootID] = .tiling(draggedRoot)
                }
            }

            let newLeaf = Slot.window(WindowSlot(
                pid: draggedWindow.pid, windowHash: draggedWindow.windowHash,
                id: UUID(), parentId: targetRoot.id,
                order: draggedWindow.order, size: .zero, gaps: true,
                preTileOrigin: draggedWindow.preTileOrigin, preTileSize: draggedWindow.preTileSize
            ))
            targetRoot.insertAdjacent(newLeaf, adjacentTo: target, zone: zone)
            let area = screenTilingArea(screen)
            targetRoot.recomputeSizes(width: area.width, height: area.height)
            store.roots[targetRootID] = .tiling(targetRoot)
        }
    }
}
