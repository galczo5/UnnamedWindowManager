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
        store.queue.sync { store.roots.values.contains { treeQuery.isTracked(key, in: $0) } }
    }

    /// Returns leaves from the root that currently has a window visible on screen.
    /// Falls back to an empty array if no root is active (no tiled windows on screen).
    func leavesInVisibleRoot() -> [Slot] {
        store.queue.sync {
            guard let id = visibleRootID(), let root = store.roots[id] else { return [] }
            return treeQuery.allLeaves(in: root).sorted { a, b in
                if case .window(let wa) = a, case .window(let wb) = b { return wa.order < wb.order }
                return false
            }
        }
    }

    /// Returns a snapshot of the root whose windows are currently visible on screen, or `nil`.
    func snapshotVisibleRoot() -> TilingRootSlot? {
        store.queue.sync {
            guard let id = visibleRootID() else { return nil }
            return store.roots[id]
        }
    }

    func storedSlot(_ key: WindowSlot) -> WindowSlot? {
        store.queue.sync {
            for root in store.roots.values {
                if let slot = treeQuery.findLeafSlot(key, in: root),
                   case .window(let w) = slot { return w }
            }
            return nil
        }
    }

    func parentOrientation(of key: WindowSlot) -> Orientation? {
        store.queue.sync {
            guard let id = rootIDSync(containing: key) else { return nil }
            return treeQuery.findParentOrientation(of: key, in: store.roots[id]!)
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
                store.roots[id] = TilingRootSlot(id: id, width: f.width, height: f.height,
                                           orientation: .horizontal, children: [])
                targetRootID = id
            }

            if treeQuery.isTracked(key, in: store.roots[targetRootID]!) { return }

            // Preserve original pre-tile values during cross-root migration.
            var preTileOrigin = key.preTileOrigin
            var preTileSize = key.preTileSize
            if let srcID = rootIDSync(containing: key) {
                if let oldSlot = treeQuery.findLeafSlot(key, in: store.roots[srcID]!),
                   case .window(let oldWindow) = oldSlot {
                    preTileOrigin = oldWindow.preTileOrigin
                    preTileSize = oldWindow.preTileSize
                }
                treeMutation.removeLeaf(key, from: &store.roots[srcID]!)
                if store.roots[srcID]!.children.isEmpty {
                    store.roots.removeValue(forKey: srcID)
                    store.windowCounts.removeValue(forKey: srcID)
                }
            }

            store.windowCounts[targetRootID, default: 0] += 1
            let order = store.windowCounts[targetRootID]!
            let newLeaf = Slot.window(WindowSlot(
                pid: key.pid, windowHash: key.windowHash,
                id: UUID(), parentId: store.roots[targetRootID]!.id,
                order: order, width: 0, height: 0, gaps: true,
                preTileOrigin: preTileOrigin, preTileSize: preTileSize
            ))
            if store.roots[targetRootID]!.children.isEmpty {
                store.roots[targetRootID]!.children = [newLeaf]
            } else {
                let lastOrder = treeQuery.maxLeafOrder(in: store.roots[targetRootID]!)
                let orientation: Orientation = order % 2 == 0 ? .horizontal : .vertical
                treeMutation.extractAndWrap(in: &store.roots[targetRootID]!, targetOrder: lastOrder,
                                    newLeaf: newLeaf, orientation: orientation)
            }
            let og = Config.outerGaps
            position.recomputeSizes(&store.roots[targetRootID]!,
                                    width: screen.visibleFrame.width  - og.left! - og.right!,
                                    height: screen.visibleFrame.height - og.top! - og.bottom!)
        }
    }

    func removeVisibleRoot() -> [WindowSlot] {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleRootID() else { return [] }
            let leaves = treeQuery.allLeaves(in: store.roots[id]!)
            store.roots.removeValue(forKey: id)
            store.windowCounts.removeValue(forKey: id)
            return leaves.compactMap { if case .window(let w) = $0 { return w } else { return nil } }
        }
    }

    func remove(_ key: WindowSlot) {
        store.queue.async(flags: .barrier) {
            guard let id = self.rootIDSync(containing: key) else { return }
            self.treeMutation.removeLeaf(key, from: &self.store.roots[id]!)
            if self.store.roots[id]!.children.isEmpty {
                self.store.roots.removeValue(forKey: id)
                self.store.windowCounts.removeValue(forKey: id)
            }
        }
    }

    func removeAndReflow(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootIDSync(containing: key) else { return }
            treeMutation.removeLeaf(key, from: &store.roots[id]!)
            if store.roots[id]!.children.isEmpty {
                store.roots.removeValue(forKey: id)
                store.windowCounts.removeValue(forKey: id)
            } else {
                let og = Config.outerGaps
                position.recomputeSizes(&store.roots[id]!,
                                        width: screen.visibleFrame.width  - og.left! - og.right!,
                                        height: screen.visibleFrame.height - og.top! - og.bottom!)
            }
        }
    }

    func resize(key: WindowSlot, actualSize: CGSize, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootIDSync(containing: key) else { return }
            resizer.applyResize(key: key, actualSize: actualSize, root: &store.roots[id]!)
            let og = Config.outerGaps
            position.recomputeSizes(&store.roots[id]!,
                                    width: screen.visibleFrame.width  - og.left! - og.right!,
                                    height: screen.visibleFrame.height - og.top! - og.bottom!)
        }
    }

    func swap(_ keyA: WindowSlot, _ keyB: WindowSlot) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootIDSync(containing: keyA),
                  treeQuery.isTracked(keyB, in: store.roots[id]!) else { return }
            treeInsert.swap(keyA, keyB, in: &store.roots[id]!)
        }
    }

    func recomputeVisibleRootSizes(screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleRootID() else { return }
            let og = Config.outerGaps
            position.recomputeSizes(&store.roots[id]!,
                                    width: screen.visibleFrame.width  - og.left! - og.right!,
                                    height: screen.visibleFrame.height - og.top! - og.bottom!)
        }
    }

    func flipParentOrientation(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootIDSync(containing: key) else { return }
            treeMutation.flipParentOrientation(of: key, in: &store.roots[id]!)
            let og = Config.outerGaps
            position.recomputeSizes(&store.roots[id]!,
                                    width: screen.visibleFrame.width  - og.left! - og.right!,
                                    height: screen.visibleFrame.height - og.top! - og.bottom!)
        }
    }

    func insertAdjacent(dragged: WindowSlot, target: WindowSlot,
                        zone: DropZone, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let draggedRootID = rootIDSync(containing: dragged),
                  let targetRootID  = rootIDSync(containing: target),
                  let draggedSlot   = treeQuery.findLeafSlot(dragged, in: store.roots[draggedRootID]!),
                  case .window(let draggedWindow) = draggedSlot else { return }

            treeMutation.removeLeaf(dragged, from: &store.roots[draggedRootID]!)
            // Destroy source root only on cross-root drag that empties it.
            if draggedRootID != targetRootID, store.roots[draggedRootID]!.children.isEmpty {
                store.roots.removeValue(forKey: draggedRootID)
                store.windowCounts.removeValue(forKey: draggedRootID)
            }

            let newLeaf = Slot.window(WindowSlot(
                pid: draggedWindow.pid, windowHash: draggedWindow.windowHash,
                id: UUID(), parentId: store.roots[targetRootID]!.id,
                order: draggedWindow.order, width: 0, height: 0, gaps: true,
                preTileOrigin: draggedWindow.preTileOrigin, preTileSize: draggedWindow.preTileSize
            ))
            treeInsert.insertAdjacentTo(newLeaf, adjacentTo: target, zone: zone, in: &store.roots[targetRootID]!)
            let og = Config.outerGaps
            position.recomputeSizes(&store.roots[targetRootID]!,
                                    width: screen.visibleFrame.width  - og.left! - og.right!,
                                    height: screen.visibleFrame.height - og.top! - og.bottom!)
        }
    }

    func rootID(containing key: WindowSlot) -> UUID? {
        store.queue.sync {
            store.roots.keys.first { treeQuery.isTracked(key, in: store.roots[$0]!) }
        }
    }

    // MARK: - Private

    /// Must be called inside a `store.queue` barrier or sync block.
    private func rootIDSync(containing key: WindowSlot) -> UUID? {
        store.roots.keys.first { treeQuery.isTracked(key, in: store.roots[$0]!) }
    }

    /// Returns the UUID of the root that owns a window currently visible on screen, or `nil`.
    /// Must be called inside a `store.queue` barrier block.
    private func visibleRootID() -> UUID? {
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let cgList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        var visibleHashes = Set<UInt>()
        for info in cgList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid   = info[kCGWindowOwnerPID as String] as? Int,
                  let wid   = info[kCGWindowNumber as String] as? CGWindowID,
                  pid_t(pid) != ownPID
            else { continue }
            visibleHashes.insert(UInt(wid))
        }

        for (id, root) in store.roots {
            for leaf in treeQuery.allLeaves(in: root) {
                if case .window(let w) = leaf, visibleHashes.contains(w.windowHash) {
                    return id
                }
            }
        }
        return nil
    }
}
