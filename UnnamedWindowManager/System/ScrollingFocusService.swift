import AppKit
import ApplicationServices

// Handles left/right navigation for scrolling roots: rotates windows between zones.
struct ScrollingFocusService {

    static func scrollLeft() {
        guard let screen = NSScreen.main else { return }
        let before = ScrollingTileService.shared.snapshotVisibleScrollingRoot()
        let newCenter = ScrollingTileService.shared.scrollLeft(screen: screen)
        guard let newCenter else { return }
        let after = ScrollingTileService.shared.snapshotVisibleScrollingRoot()
        LayoutService.shared.applyLayout(screen: screen, zonesChanged: zoneSignature(before) != zoneSignature(after))
        activateAfterLayout(newCenter)
    }

    static func scrollRight() {
        guard let screen = NSScreen.main else { return }
        let before = ScrollingTileService.shared.snapshotVisibleScrollingRoot()
        let newCenter = ScrollingTileService.shared.scrollRight(screen: screen)
        guard let newCenter else { return }
        let after = ScrollingTileService.shared.snapshotVisibleScrollingRoot()
        LayoutService.shared.applyLayout(screen: screen, zonesChanged: zoneSignature(before) != zoneSignature(after))
        activateAfterLayout(newCenter)
    }

    private static func zoneSignature(_ root: ScrollingRootSlot?) -> (Bool, Bool) {
        (root?.left != nil, root?.right != nil)
    }

    private static func activateAfterLayout(_ key: WindowSlot) {
        guard let ax = ResizeObserver.shared.elements[key] else { return }
        NSRunningApplication(processIdentifier: key.pid)?.activate()
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
    }
}
