import AppKit

/// Read-only queries and lookup helpers for tiling roots in SharedRootStore.
final class TilingRootStore {
    static let shared = TilingRootStore()
    private init() {}

    private let store = SharedRootStore.shared

    func isTracked(_ key: WindowSlot) -> Bool {
        return store.queue.sync {
            store.roots.values.contains {
                guard case .tiling(let root) = $0 else { return false }
                return root.isTracked(key)
            }
        }
    }

    /// Returns leaves from the root that currently has a window visible on screen.
    func leavesInVisibleRoot() -> [Slot] {
        return store.queue.sync {
            guard let id = visibleRootID(),
                  case .tiling(let root) = store.roots[id] else { return [] }
            return root.allLeaves().sorted { a, b in
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
                if let slot = root.findLeaf(key), case .window(let w) = slot { return w }
            }
            return nil
        }
    }

    func parentOrientation(of key: WindowSlot) -> Orientation? {
        return store.queue.sync {
            guard let id = rootIDSync(containing: key),
                  case .tiling(let root) = store.roots[id] else { return nil }
            return root.parentOrientation(of: key)
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
            return root.isTracked(key)
        }?.key
    }

    /// Returns the UUID of the tiling root that owns a window currently visible on screen, or `nil`.
    func visibleRootID() -> UUID? {
        let onScreen = WindowOnScreenCache.visibleSet()
        let tilingRoots = store.roots.filter { if case .tiling = $0.value { return true }; return false }
        Logger.shared.log("[TilingRootStore] visibleRootID: checking \(tilingRoots.count) tiling root(s), \(onScreen.count) windows on screen")
        for (id, rootSlot) in store.roots {
            guard case .tiling(let root) = rootSlot else { continue }
            for leaf in root.allLeaves() {
                if case .window(let w) = leaf {
                    let visible = onScreen.contains(pid: w.pid, hash: w.windowHash)
                    Logger.shared.log("[TilingRootStore] root=\(id.uuidString.prefix(8)) wid=\(w.windowHash) pid=\(w.pid) onScreen=\(visible)")
                    if visible { return id }
                }
            }
        }
        Logger.shared.log("[TilingRootStore] visibleRootID: no visible root found")
        return nil
    }
}
