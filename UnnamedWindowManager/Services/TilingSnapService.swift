import AppKit

/// Adds and removes windows from tiling roots in SharedRootStore.
final class TilingSnapService {
    static let shared = TilingSnapService()
    private init() {}

    private let store        = SharedRootStore.shared
    private let rootStore    = TilingRootStore.shared
    private let treeQuery    = TilingTreeQueryService()
    private let treeMutation = TilingTreeMutationService()
    private let position     = TilingPositionService()

    /// Tiles `key` into the correct root, creating one if no tiled window is visible on screen.
    /// Idempotent: no-op if the window is already in the correct root.
    /// Performs a cross-root migration if the window belongs to a different root.
    func snap(_ key: WindowSlot, screen: NSScreen) {
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
            if treeQuery.isTracked(key, in: targetRoot) {
                return
            }

            // Preserve original pre-tile values during cross-root migration.
            var preTileOrigin = key.preTileOrigin
            var preTileSize = key.preTileSize
            if let srcID = rootStore.rootIDSync(containing: key),
               case .tiling(var srcRoot) = store.roots[srcID] {
                if let oldSlot = treeQuery.findLeafSlot(key, in: srcRoot),
                   case .window(let oldWindow) = oldSlot {
                    preTileOrigin = oldWindow.preTileOrigin
                    preTileSize = oldWindow.preTileSize
                }
                treeMutation.removeLeaf(key, from: &srcRoot)
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
                let lastOrder = treeQuery.maxLeafOrder(in: targetRoot)
                let orientation: Orientation = order % 2 == 0 ? .horizontal : .vertical
                treeMutation.extractAndWrap(in: &targetRoot, targetOrder: lastOrder,
                                            newLeaf: newLeaf, orientation: orientation)
            }
            let area = screenTilingArea(screen)
            position.recomputeSizes(&targetRoot, width: area.width, height: area.height)
            store.roots[targetRootID] = .tiling(targetRoot)
        }
    }

    func removeVisibleRoot() -> [WindowSlot] {
        return store.queue.sync(flags: .barrier) {
            guard let id = rootStore.visibleRootID(),
                  case .tiling(let root) = store.roots[id] else { return [] }
            let leaves = treeQuery.allLeaves(in: root)
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
                all += treeQuery.allLeaves(in: root).compactMap { if case .window(let w) = $0 { return w } else { return nil } }
                store.removeRoot(id: id)
            }
            return all
        }
    }

    func remove(_ key: WindowSlot) {
        store.queue.async(flags: .barrier) {
            guard let id = self.rootStore.rootIDSync(containing: key),
                  case .tiling(var root) = self.store.roots[id] else { return }
            self.treeMutation.removeLeaf(key, from: &root)
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
            treeMutation.removeLeaf(key, from: &root)
            if root.children.isEmpty {
                store.removeRoot(id: id)
            } else {
                let area = screenTilingArea(screen)
                position.recomputeSizes(&root, width: area.width, height: area.height)
                store.roots[id] = .tiling(root)
            }
        }
    }
}
