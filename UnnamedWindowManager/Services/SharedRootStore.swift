import AppKit

// Thread-safe store for all layout roots, accessed via a concurrent dispatch queue.
final class SharedRootStore {
    static let shared = SharedRootStore()
    private init() {}

    var roots: [UUID: TilingRootSlot] = [:]
    /// Per-root insertion counter used to assign `WindowSlot.order`.
    var windowCounts: [UUID: Int] = [:]
    let queue = DispatchQueue(label: "snap.registry", attributes: .concurrent)

    func snapshotAllRoots() -> [UUID: TilingRootSlot] {
        queue.sync { roots }
    }

    func snapshotRoot(id: UUID) -> TilingRootSlot? {
        queue.sync { roots[id] }
    }
}
