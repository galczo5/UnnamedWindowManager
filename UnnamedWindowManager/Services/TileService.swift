import AppKit

// High-level operations on the tiling layout: adding, removing, resizing, and repositioning windows.
final class TileService {
    static let shared = TileService()
    private init() {}

    private let store        = SharedRootStore.shared
    private let treeQuery    = SlotTreeQueryService()
    private let treeMutation = SlotTreeMutationService()
    private let treeInsert   = SlotTreeInsertService()
    private let position     = PositionService()
    private let resizer      = ResizeService()

    // MARK: - Queries

    func isTracked(_ key: WindowSlot) -> Bool {
        return store.queue.sync {
            store.roots.values.contains {
                guard case .tiling(let root) = $0 else { return false }
                return treeQuery.isTracked(key, in: root)
            }
        }
    }

    /// Returns leaves from the root that currently has a window visible on screen.
    /// Falls back to an empty array if no root is active (no tiled windows on screen).
    func leavesInVisibleRoot() -> [Slot] {
        return store.queue.sync {
            guard let id = visibleRootID(),
                  case .tiling(let root) = store.roots[id] else { return [] }
            return treeQuery.allLeaves(in: root).sorted { a, b in
                if case .window(let wa) = a, case .window(let wb) = b { return wa.order < wb.order }
                return false
            }
        }
    }

    /// Returns a snapshot of the root whose windows are currently visible on screen, or `nil`.
    func snapshotVisibleRoot() -> TilingRootSlot? {
        return store.queue.sync {
            guard let id = visibleRootID(),
                  case .tiling(let root) = store.roots[id] else { return nil }
            return root
        }
    }

    func storedSlot(_ key: WindowSlot) -> WindowSlot? {
        return store.queue.sync {
            for rootSlot in store.roots.values {
                guard case .tiling(let root) = rootSlot else { continue }
                if let slot = treeQuery.findLeafSlot(key, in: root),
                   case .window(let w) = slot { return w }
            }
            return nil
        }
    }

    func parentOrientation(of key: WindowSlot) -> Orientation? {
        return store.queue.sync {
            guard let id = rootIDSync(containing: key),
                  case .tiling(let root) = store.roots[id] else { return nil }
            return treeQuery.findParentOrientation(of: key, in: root)
        }
    }

    // MARK: - Tile / untile

    /// Tiles `key` into the correct root, creating one if no tiled window is visible on screen.
    /// Idempotent: no-op if the window is already in the correct root.
    /// Performs a cross-root migration if the window belongs to a different root.
    func snap(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            // Determine target root — the one with a visible tiled window, or a brand-new root.
            let targetRootID: UUID
            if let visibleID = visibleRootID() {
                targetRootID = visibleID
            } else {
                let id = UUID()
                let f  = screen.visibleFrame
                store.roots[id] = .tiling(TilingRootSlot(id: id, width: f.width, height: f.height,
                                                         orientation: .horizontal, children: []))
                targetRootID = id
            }

            guard case .tiling(var targetRoot) = store.roots[targetRootID] else { return }
            if treeQuery.isTracked(key, in: targetRoot) {
                return
            }

            // Preserve original pre-tile values during cross-root migration.
            var preTileOrigin = key.preTileOrigin
            var preTileSize = key.preTileSize
            if let srcID = rootIDSync(containing: key),
               case .tiling(var srcRoot) = store.roots[srcID] {
                if let oldSlot = treeQuery.findLeafSlot(key, in: srcRoot),
                   case .window(let oldWindow) = oldSlot {
                    preTileOrigin = oldWindow.preTileOrigin
                    preTileSize = oldWindow.preTileSize
                }
                treeMutation.removeLeaf(key, from: &srcRoot)
                if srcRoot.children.isEmpty {
                    store.roots.removeValue(forKey: srcID)
                    store.windowCounts.removeValue(forKey: srcID)
                } else {
                    store.roots[srcID] = .tiling(srcRoot)
                }
            }

            store.windowCounts[targetRootID, default: 0] += 1
            let order = store.windowCounts[targetRootID]!
            let newLeaf = Slot.window(WindowSlot(
                pid: key.pid, windowHash: key.windowHash,
                id: UUID(), parentId: targetRoot.id,
                order: order, width: 0, height: 0, gaps: true,
                preTileOrigin: preTileOrigin, preTileSize: preTileSize
            ))
            if targetRoot.children.isEmpty {
                targetRoot.children = [newLeaf]
            } else {
                let lastOrder = treeQuery.maxLeafOrder(in: targetRoot)
                let orientation: Orientation = order % 2 == 0 ? .horizontal : .vertical
                treeMutation.extractAndWrap(in: &targetRoot, targetOrder: lastOrder,
                                            newLeaf: newLeaf, orientation: orientation)
            }
            let og = Config.outerGaps
            position.recomputeSizes(&targetRoot,
                                    width: screen.visibleFrame.width  - og.left! - og.right!,
                                    height: screen.visibleFrame.height - og.top! - og.bottom!)
            store.roots[targetRootID] = .tiling(targetRoot)
        }
    }

    func removeVisibleRoot() -> [WindowSlot] {
        return store.queue.sync(flags: .barrier) {
            guard let id = visibleRootID(),
                  case .tiling(let root) = store.roots[id] else { return [] }
            let leaves = treeQuery.allLeaves(in: root)
            store.roots.removeValue(forKey: id)
            store.windowCounts.removeValue(forKey: id)
            return leaves.compactMap { if case .window(let w) = $0 { return w } else { return nil } }
        }
    }

    func remove(_ key: WindowSlot) {
        store.queue.async(flags: .barrier) {
            guard let id = self.rootIDSync(containing: key),
                  case .tiling(var root) = self.store.roots[id] else { return }
            self.treeMutation.removeLeaf(key, from: &root)
            if root.children.isEmpty {
                self.store.roots.removeValue(forKey: id)
                self.store.windowCounts.removeValue(forKey: id)
            } else {
                self.store.roots[id] = .tiling(root)
            }
        }
    }

    func removeAndReflow(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootIDSync(containing: key),
                  case .tiling(var root) = store.roots[id] else { return }
            treeMutation.removeLeaf(key, from: &root)
            if root.children.isEmpty {
                store.roots.removeValue(forKey: id)
                store.windowCounts.removeValue(forKey: id)
            } else {
                let og = Config.outerGaps
                position.recomputeSizes(&root,
                                        width: screen.visibleFrame.width  - og.left! - og.right!,
                                        height: screen.visibleFrame.height - og.top! - og.bottom!)
                store.roots[id] = .tiling(root)
            }
        }
    }

    func resize(key: WindowSlot, actualSize: CGSize, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootIDSync(containing: key),
                  case .tiling(var root) = store.roots[id] else { return }
            resizer.applyResize(key: key, actualSize: actualSize, root: &root)
            let og = Config.outerGaps
            position.recomputeSizes(&root,
                                    width: screen.visibleFrame.width  - og.left! - og.right!,
                                    height: screen.visibleFrame.height - og.top! - og.bottom!)
            store.roots[id] = .tiling(root)
        }
    }

    func swap(_ keyA: WindowSlot, _ keyB: WindowSlot) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootIDSync(containing: keyA),
                  case .tiling(var root) = store.roots[id],
                  treeQuery.isTracked(keyB, in: root) else {
                return
            }
            treeInsert.swap(keyA, keyB, in: &root)
            store.roots[id] = .tiling(root)
        }
    }

    func recomputeVisibleRootSizes(screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleRootID(),
                  case .tiling(var root) = store.roots[id] else { return }
            let og = Config.outerGaps
            position.recomputeSizes(&root,
                                    width: screen.visibleFrame.width  - og.left! - og.right!,
                                    height: screen.visibleFrame.height - og.top! - og.bottom!)
            store.roots[id] = .tiling(root)
        }
    }

    func flipParentOrientation(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootIDSync(containing: key),
                  case .tiling(var root) = store.roots[id] else { return }
            treeMutation.flipParentOrientation(of: key, in: &root)
            let og = Config.outerGaps
            position.recomputeSizes(&root,
                                    width: screen.visibleFrame.width  - og.left! - og.right!,
                                    height: screen.visibleFrame.height - og.top! - og.bottom!)
            store.roots[id] = .tiling(root)
        }
    }

    func insertAdjacent(dragged: WindowSlot, target: WindowSlot,
                        zone: DropZone, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let draggedRootID = rootIDSync(containing: dragged),
                  let targetRootID  = rootIDSync(containing: target),
                  case .tiling(var draggedRoot) = store.roots[draggedRootID],
                  case .tiling(var targetRoot)  = store.roots[targetRootID],
                  let draggedSlot = treeQuery.findLeafSlot(dragged, in: draggedRoot),
                  case .window(let draggedWindow) = draggedSlot else {
                return
            }

            treeMutation.removeLeaf(dragged, from: &draggedRoot)
            // Destroy source root only on cross-root drag that empties it.
            if draggedRootID != targetRootID {
                if draggedRoot.children.isEmpty {
                    store.roots.removeValue(forKey: draggedRootID)
                    store.windowCounts.removeValue(forKey: draggedRootID)
                } else {
                    store.roots[draggedRootID] = .tiling(draggedRoot)
                }
            }

            let newLeaf = Slot.window(WindowSlot(
                pid: draggedWindow.pid, windowHash: draggedWindow.windowHash,
                id: UUID(), parentId: targetRoot.id,
                order: draggedWindow.order, width: 0, height: 0, gaps: true,
                preTileOrigin: draggedWindow.preTileOrigin, preTileSize: draggedWindow.preTileSize
            ))
            treeInsert.insertAdjacentTo(newLeaf, adjacentTo: target, zone: zone, in: &targetRoot)
            let og = Config.outerGaps
            position.recomputeSizes(&targetRoot,
                                    width: screen.visibleFrame.width  - og.left! - og.right!,
                                    height: screen.visibleFrame.height - og.top! - og.bottom!)
            store.roots[targetRootID] = .tiling(targetRoot)
        }
    }

    func rootID(containing key: WindowSlot) -> UUID? {
        return store.queue.sync {
            store.roots.first { _, rootSlot in
                guard case .tiling(let root) = rootSlot else { return false }
                return treeQuery.isTracked(key, in: root)
            }?.key
        }
    }

    // MARK: - Private

    /// Must be called inside a `store.queue` barrier or sync block.
    private func rootIDSync(containing key: WindowSlot) -> UUID? {
        store.roots.first { _, rootSlot in
            guard case .tiling(let root) = rootSlot else { return false }
            return treeQuery.isTracked(key, in: root)
        }?.key
    }

    /// Returns the UUID of the root that owns a window currently visible on screen, or `nil`.
    /// Must be called inside a `store.queue` barrier block.
    private func visibleRootID() -> UUID? {
        let visibleHashes = OnScreenWindowCache.visibleHashes()
        for (id, rootSlot) in store.roots {
            guard case .tiling(let root) = rootSlot else { continue }
            for leaf in treeQuery.allLeaves(in: root) {
                if case .window(let w) = leaf, visibleHashes.contains(w.windowHash) {
                    return id
                }
            }
        }
        return nil
    }
}
