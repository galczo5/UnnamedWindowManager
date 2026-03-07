import AppKit

// High-level operations on the snap layout: adding, removing, resizing, and repositioning windows.
final class SnapService {
    static let shared = SnapService()
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
    /// Falls back to an empty array if no root is active (no snapped windows on screen).
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
    func snapshotVisibleRoot() -> RootSlot? {
        store.queue.sync {
            guard let id = visibleRootID() else { return nil }
            return store.roots[id]
        }
    }

    func parentOrientation(of key: WindowSlot) -> Orientation? {
        store.queue.sync {
            guard let id = rootID(containing: key) else { return nil }
            return treeQuery.findParentOrientation(of: key, in: store.roots[id]!)
        }
    }

    // MARK: - Snap / unsnap

    /// Snaps `key` into the correct root, creating one if no snapped window is visible on screen.
    /// Idempotent: no-op if the window is already in the correct root.
    /// Performs a cross-root migration if the window belongs to a different root.
    func snap(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            // Determine target root — the one with a visible snapped window, or a brand-new root.
            let targetRootID: UUID
            if let visibleID = visibleRootID() {
                targetRootID = visibleID
            } else {
                let id = UUID()
                let f  = screen.visibleFrame
                store.roots[id] = RootSlot(id: id, width: f.width, height: f.height,
                                           orientation: .horizontal, children: [])
                targetRootID = id
            }

            if treeQuery.isTracked(key, in: store.roots[targetRootID]!) { return }

            // Cross-root migration: remove from old root, destroy root if now empty.
            if let srcID = rootID(containing: key) {
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
                order: order, width: 0, height: 0, gaps: true
            ))
            if store.roots[targetRootID]!.children.isEmpty {
                store.roots[targetRootID]!.children = [newLeaf]
            } else {
                let lastOrder = treeQuery.maxLeafOrder(in: store.roots[targetRootID]!)
                let orientation: Orientation = order % 2 == 0 ? .horizontal : .vertical
                treeMutation.extractAndWrap(in: &store.roots[targetRootID]!, targetOrder: lastOrder,
                                    newLeaf: newLeaf, orientation: orientation)
            }
            position.recomputeSizes(&store.roots[targetRootID]!,
                                    width: screen.visibleFrame.width  - Config.gap * 2,
                                    height: screen.visibleFrame.height - Config.gap * 2)
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
            guard let id = self.rootID(containing: key) else { return }
            self.treeMutation.removeLeaf(key, from: &self.store.roots[id]!)
            if self.store.roots[id]!.children.isEmpty {
                self.store.roots.removeValue(forKey: id)
                self.store.windowCounts.removeValue(forKey: id)
            }
        }
    }

    func removeAndReflow(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootID(containing: key) else { return }
            treeMutation.removeLeaf(key, from: &store.roots[id]!)
            if store.roots[id]!.children.isEmpty {
                store.roots.removeValue(forKey: id)
                store.windowCounts.removeValue(forKey: id)
            } else {
                position.recomputeSizes(&store.roots[id]!,
                                        width: screen.visibleFrame.width  - Config.gap * 2,
                                        height: screen.visibleFrame.height - Config.gap * 2)
            }
        }
    }

    func resize(key: WindowSlot, actualSize: CGSize, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootID(containing: key) else { return }
            resizer.applyResize(key: key, actualSize: actualSize, root: &store.roots[id]!)
            position.recomputeSizes(&store.roots[id]!,
                                    width: screen.visibleFrame.width  - Config.gap * 2,
                                    height: screen.visibleFrame.height - Config.gap * 2)
        }
    }

    func swap(_ keyA: WindowSlot, _ keyB: WindowSlot) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootID(containing: keyA),
                  treeQuery.isTracked(keyB, in: store.roots[id]!) else { return }
            treeInsert.swap(keyA, keyB, in: &store.roots[id]!)
        }
    }

    func flipParentOrientation(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = rootID(containing: key) else { return }
            treeMutation.flipParentOrientation(of: key, in: &store.roots[id]!)
            position.recomputeSizes(&store.roots[id]!,
                                    width: screen.visibleFrame.width  - Config.gap * 2,
                                    height: screen.visibleFrame.height - Config.gap * 2)
        }
    }

    func insertAdjacent(dragged: WindowSlot, target: WindowSlot,
                        zone: DropZone, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let draggedRootID = rootID(containing: dragged),
                  let targetRootID  = rootID(containing: target),
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
                order: draggedWindow.order, width: 0, height: 0, gaps: true
            ))
            treeInsert.insertAdjacentTo(newLeaf, adjacentTo: target, zone: zone, in: &store.roots[targetRootID]!)
            position.recomputeSizes(&store.roots[targetRootID]!,
                                    width: screen.visibleFrame.width  - Config.gap * 2,
                                    height: screen.visibleFrame.height - Config.gap * 2)
        }
    }

    // MARK: - Private

    /// Must be called inside a `store.queue` barrier or sync block.
    private func rootID(containing key: WindowSlot) -> UUID? {
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
