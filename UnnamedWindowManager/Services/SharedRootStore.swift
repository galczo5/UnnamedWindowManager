import AppKit

// Which root type (tiling or scrolling) is active on the current space.
enum ActiveRootType {
    case tiling
    case scrolling
}

// Thread-safe store for all layout roots, accessed via a concurrent dispatch queue.
final class SharedRootStore {
    static let shared = SharedRootStore()
    private init() {}

    var roots: [UUID: RootSlot] = [:]
    /// Per-root insertion counter used to assign `WindowSlot.order`.
    var windowCounts: [UUID: Int] = [:]
    let queue = DispatchQueue(label: "snap.registry", attributes: .concurrent)

    /// The root type most recently determined to be active on the current space.
    /// Updated by SpaceChangeObserver on each space switch.
    private(set) var activeRootType: ActiveRootType?

    func setActiveRootType(_ type: ActiveRootType?) {
        queue.async(flags: .barrier) { [self] in
            activeRootType = type
        }
    }

    /// Removes a root and its window counter. Must be called inside a barrier block on `queue`.
    func removeRoot(id: UUID) {
        roots.removeValue(forKey: id)
        windowCounts.removeValue(forKey: id)
    }

    func snapshotAllRoots() -> [UUID: RootSlot] {
        return queue.sync { roots }
    }
}
