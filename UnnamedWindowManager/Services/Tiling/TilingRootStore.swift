import AppKit

/// Read-only queries and lookup helpers for tiling roots in SharedRootStore.
final class TilingRootStore {
    static let shared = TilingRootStore()
    private init() {}

    private let store     = SharedRootStore.shared
    private let treeQuery = TilingTreeQueryService()

    func isTracked(_ key: WindowSlot) -> Bool {
        return store.queue.sync {
            store.roots.values.contains {
                guard case .tiling(let root) = $0 else { return false }
                return treeQuery.isTracked(key, in: root)
            }
        }
    }

    /// Returns leaves from the root that currently has a window visible on screen.
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

    func rootID(containing key: WindowSlot) -> UUID? {
        return store.queue.sync {
            rootIDSync(containing: key)
        }
    }

    // MARK: - Internal lookup helpers (must be called inside store.queue block)

    /// Returns the UUID of the tiling root containing `key`, or `nil`.
    func rootIDSync(containing key: WindowSlot) -> UUID? {
        store.roots.first { _, rootSlot in
            guard case .tiling(let root) = rootSlot else { return false }
            return treeQuery.isTracked(key, in: root)
        }?.key
    }

    /// Returns the UUID of the tiling root that owns a window currently visible on screen, or `nil`.
    func visibleRootID() -> UUID? {
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
