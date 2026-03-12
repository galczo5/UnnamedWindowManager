import AppKit
import ApplicationServices

// Handles left/right navigation for scrolling roots: rotates windows between zones.
struct ScrollingFocusService {

    static func scrollLeft() {
        guard let screen = NSScreen.main else { return }
        let before = ScrollingTileService.shared.snapshotVisibleScrollingRoot()
        let newCenter = ScrollingTileService.shared.scrollLeft(screen: screen)
        Logger.shared.log("scrollLeft: newCenter=\(newCenter.map { "pid=\($0.pid) hash=\($0.windowHash)" } ?? "nil")")
        guard let newCenter else { return }
        let after = ScrollingTileService.shared.snapshotVisibleScrollingRoot()
        LayoutService.shared.applyLayout(screen: screen, zonesChanged: zoneSignature(before) != zoneSignature(after))
        activateAfterLayout(newCenter)
    }

    static func scrollRight() {
        guard let screen = NSScreen.main else { return }
        let before = ScrollingTileService.shared.snapshotVisibleScrollingRoot()
        let newCenter = ScrollingTileService.shared.scrollRight(screen: screen)
        Logger.shared.log("scrollRight: newCenter=\(newCenter.map { "pid=\($0.pid) hash=\($0.windowHash)" } ?? "nil")")
        guard let newCenter else { return }
        let after = ScrollingTileService.shared.snapshotVisibleScrollingRoot()
        LayoutService.shared.applyLayout(screen: screen, zonesChanged: zoneSignature(before) != zoneSignature(after))
        activateAfterLayout(newCenter)
    }

    private static func zoneSignature(_ root: ScrollingRootSlot?) -> (Bool, Bool) {
        (root?.left != nil, root?.right != nil)
    }

    /// Activates the center window after the layout pass completes.
    /// ReapplyHandler debounces at 100ms, so 200ms ensures layout has finished.
    private static func activateAfterLayout(_ key: WindowSlot) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let ax = ResizeObserver.shared.elements[key] else { return }
            NSRunningApplication(processIdentifier: key.pid)?.activate()
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        }
    }
}
