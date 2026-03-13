import AppKit

// Thread-safe store for all layout roots, accessed via a concurrent dispatch queue.
final class SharedRootStore {
    static let shared = SharedRootStore()
    private init() {}

    var roots: [UUID: RootSlot] = [:]
    /// Per-root insertion counter used to assign `WindowSlot.order`.
    var windowCounts: [UUID: Int] = [:]
    let queue = DispatchQueue(label: "snap.registry", attributes: .concurrent)

    func snapshotAllRoots() -> [UUID: RootSlot] {
        return queue.sync { roots }
    }

    func snapshotRoot(id: UUID) -> RootSlot? {
        return queue.sync { roots[id] }
    }
}
