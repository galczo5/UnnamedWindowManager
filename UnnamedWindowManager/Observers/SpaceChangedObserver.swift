import AppKit

// Wraps NSWorkspace.activeSpaceDidChangeNotification as a pub/sub event.
// Handles displaced-window untiling and root-type bookkeeping internally;
// subscribers receive SpaceChangedEvent after all internal state has settled.
final class SpaceChangedObserver: EventObserver<SpaceChangedEvent> {
    static let shared = SpaceChangedObserver()

    private var lastTilingRootID: UUID?
    private var lastScrollingRootID: UUID?

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @objc private func activeSpaceDidChange() {
        OnScreenWindowCache.invalidate()
        untileDisplacedWindows()
        ReapplyHandler.reapplyAll()

        let tilingRoot = TilingRootStore.shared.snapshotVisibleRoot()
        let scrollingRoot = ScrollingRootStore.shared.snapshotVisibleScrollingRoot()

        if let root = tilingRoot {
            if root.id != lastTilingRootID {
                lastTilingRootID = root.id
                let count = TilingTreeQueryService().allLeaves(in: root).count
                WindowLister.logRootChanged(type: "tiling", rootID: root.id, windowCount: count)
            }
        } else {
            lastTilingRootID = nil
        }

        if let root = scrollingRoot {
            if root.id != lastScrollingRootID {
                lastScrollingRootID = root.id
                WindowLister.logRootChanged(type: "scrolling", rootID: root.id,
                                            windowCount: WindowLister.countScrollingWindows(in: root))
            }
        } else {
            lastScrollingRootID = nil
        }

        if tilingRoot != nil && scrollingRoot == nil {
            SharedRootStore.shared.setActiveRootType(.tiling)
        } else if scrollingRoot != nil && tilingRoot == nil {
            SharedRootStore.shared.setActiveRootType(.scrolling)
        } else if tilingRoot == nil && scrollingRoot == nil {
            SharedRootStore.shared.setActiveRootType(nil)
        }
        // Both visible: keep current activeRootType (CGWindowList cross-space bleed).

        notify(SpaceChangedEvent())
    }

    private func untileDisplacedWindows() {
        guard let screen = NSScreen.main else { return }
        let visibleHashes = OnScreenWindowCache.visibleHashes()
        let toUntile = displacedWindows(visibleHashes: visibleHashes)
        for key in toUntile {
            UntileHandler.untileByKey(key, screen: screen)
        }
    }

    private func displacedWindows(visibleHashes: Set<UInt>) -> [WindowSlot] {
        SharedRootStore.shared.queue.sync {
            var displaced: [WindowSlot] = []
            for (_, rootSlot) in SharedRootStore.shared.roots {
                let leaves = allWindowSlots(in: rootSlot)
                let visible = leaves.filter { visibleHashes.contains($0.windowHash) }
                let hidden  = leaves.filter { !visibleHashes.contains($0.windowHash) }
                if !visible.isEmpty && !hidden.isEmpty {
                    displaced.append(contentsOf: visible)
                }
            }
            return displaced
        }
    }

    private func allWindowSlots(in rootSlot: RootSlot) -> [WindowSlot] {
        switch rootSlot {
        case .tiling(let root):
            return TilingTreeQueryService().allLeaves(in: root).compactMap {
                guard case .window(let w) = $0 else { return nil }
                return w
            }
        case .scrolling(let root):
            var slots: [WindowSlot] = []
            for slot in [root.left, Optional(root.center), root.right].compactMap({ $0 }) {
                switch slot {
                case .window(let w):    slots.append(w)
                case .stacking(let s): slots.append(contentsOf: s.children)
                default: break
                }
            }
            return slots
        }
    }
}
