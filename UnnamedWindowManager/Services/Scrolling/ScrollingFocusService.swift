import AppKit
import ApplicationServices

// Handles left/right navigation for scrolling roots: rotates windows between zones.
struct ScrollingFocusService {

    static func scrollLeft() {
        guard let screen = NSScreen.main else { return }
        let before = ScrollingRootStore.shared.snapshotVisibleScrollingRoot()
        let newCenter = ScrollingRootStore.shared.scrollLeft(screen: screen)
        guard let newCenter else { return }
        let after = ScrollingRootStore.shared.snapshotVisibleScrollingRoot()
        guard let after else { return }
        let zonesChanged = zoneSignature(before) != zoneSignature(after)
        let origin = layoutOrigin(screen: screen)
        let elements = ResizeObserver.shared.elements

        // Move 1: old center to side
        ScrollingLayoutService.shared.applyLayout(root: after, origin: origin, elements: elements,
                                                   zonesChanged: zonesChanged, applyCenter: false)
        // Move 2: new center to center position
        ScrollingLayoutService.shared.applyLayout(root: after, origin: origin, elements: elements,
                                                   applySides: false)
        activateAfterLayout(newCenter)
    }

    static func scrollRight() {
        guard let screen = NSScreen.main else { return }
        let before = ScrollingRootStore.shared.snapshotVisibleScrollingRoot()
        let newCenter = ScrollingRootStore.shared.scrollRight(screen: screen)
        guard let newCenter else { return }
        let after = ScrollingRootStore.shared.snapshotVisibleScrollingRoot()
        guard let after else { return }
        let zonesChanged = zoneSignature(before) != zoneSignature(after)
        let origin = layoutOrigin(screen: screen)
        let elements = ResizeObserver.shared.elements

        // Move 1: old center to side
        ScrollingLayoutService.shared.applyLayout(root: after, origin: origin, elements: elements,
                                                   zonesChanged: zonesChanged, applyCenter: false)
        // Move 2: new center to center position
        ScrollingLayoutService.shared.applyLayout(root: after, origin: origin, elements: elements,
                                                   applySides: false)
        activateAfterLayout(newCenter)
    }

    static func scrollToCenter(key: WindowSlot) {
        guard let screen = NSScreen.main else { return }
        let before = ScrollingRootStore.shared.snapshotVisibleScrollingRoot()
        guard let newCenter = ScrollingRootStore.shared.scrollToWindow(key, screen: screen) else { return }
        guard let after = ScrollingRootStore.shared.snapshotVisibleScrollingRoot() else { return }
        let zonesChanged = zoneSignature(before) != zoneSignature(after)
        let origin = layoutOrigin(screen: screen)
        let elements = ResizeObserver.shared.elements

        ScrollingLayoutService.shared.applyLayout(root: after, origin: origin, elements: elements,
                                                   zonesChanged: zonesChanged, applyCenter: false)
        ScrollingLayoutService.shared.applyLayout(root: after, origin: origin, elements: elements,
                                                   applySides: false)
        activateAfterLayout(newCenter)
    }

    private static func zoneSignature(_ root: ScrollingRootSlot?) -> (Bool, Bool) {
        (root?.left != nil, root?.right != nil)
    }

    private static func layoutOrigin(screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        let primaryHeight = NSScreen.screens[0].frame.height
        let og = Config.outerGaps
        return CGPoint(x: visible.minX + og.left!, y: primaryHeight - visible.maxY + og.top!)
    }

    private static func activateAfterLayout(_ key: WindowSlot) {
        guard let ax = ResizeObserver.shared.elements[key] else { return }
        NSRunningApplication(processIdentifier: key.pid)?.activate()
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
    }
}
