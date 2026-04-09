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
        untileDisplacedWindows()
        ReapplyHandler.reapplyAll()

        let tilingRoot = TilingRootStore.shared.snapshotVisibleRoot()
        let scrollingRoot = ScrollingRootStore.shared.snapshotVisibleScrollingRoot()

        if let root = tilingRoot {
            if root.id != lastTilingRootID {
                lastTilingRootID = root.id
                let count = root.allLeaves().count
                DebugLogger.logRootChanged(type: "tiling", rootID: root.id, windowCount: count)
            }
        } else {
            lastTilingRootID = nil
        }

        if let root = scrollingRoot {
            if root.id != lastScrollingRootID {
                lastScrollingRootID = root.id
                DebugLogger.logRootChanged(type: "scrolling", rootID: root.id,
                                            windowCount: DebugLogger.countScrollingWindows(in: root))
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
        let onScreen = WindowOnScreenCache.visibleSet()
        let toUntile = displacedWindows(onScreen: onScreen)
        for key in toUntile {
            UntileHandler.untileByKey(key, screen: screen)
        }
    }

    private func displacedWindows(onScreen: Set<OnScreenWindow>) -> [WindowSlot] {
        SharedRootStore.shared.queue.sync {
            var displaced: [WindowSlot] = []
            for (_, rootSlot) in SharedRootStore.shared.roots {
                let leaves = allWindowSlots(in: rootSlot)
                let visible = leaves.filter { onScreen.contains(pid: $0.pid, hash: $0.windowHash) }
                let hidden  = leaves.filter { !onScreen.contains(pid: $0.pid, hash: $0.windowHash) }
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
            return root.allLeaves().compactMap {
                guard case .window(let w) = $0 else { return nil }
                return w
            }
        case .scrolling(let root):
            return root.allWindowSlots()
        }
    }
}
