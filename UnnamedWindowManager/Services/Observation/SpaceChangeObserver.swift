import AppKit

// Observes macOS space (desktop) switches and logs which tiling/scrolling root becomes visible.
final class SpaceChangeObserver {
    static let shared = SpaceChangeObserver()
    private init() {}

    private var lastTilingRootID: UUID?
    private var lastScrollingRootID: UUID?

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    @objc private func activeSpaceDidChange() {
        // Flush the cache so visibleRootID reflects the new space's windows.
        OnScreenWindowCache.invalidate()

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
    }
}
