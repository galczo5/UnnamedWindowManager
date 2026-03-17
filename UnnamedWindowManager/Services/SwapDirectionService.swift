import AppKit
import ApplicationServices

// Swaps the focused window with its directional neighbour, for both tiling and scrolling layouts.
struct SwapDirectionService {

    static func swap(_ direction: FocusDirection) {
        if ScrollingTileService.shared.snapshotVisibleScrollingRoot() != nil {
            swapInScrollRoot(direction: direction)
            return
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success else { return }
        let axWindow = ref as! AXUIElement
        let currentKey = windowSlot(for: axWindow, pid: pid)
        swapInTilingRoot(direction: direction, currentKey: currentKey)
    }

    // MARK: - Private

    private static func swapInScrollRoot(direction: FocusDirection) {
        guard let screen = NSScreen.main else { return }
        guard let moved = ScrollingTileService.shared.swapWindows(direction, screen: screen) else { return }
        ReapplyHandler.reapplyAll()
        guard let ax = ResizeObserver.shared.elements[moved] else { return }
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
    }

    private static func swapInTilingRoot(direction: FocusDirection, currentKey: WindowSlot) {
        guard let root = TileService.shared.snapshotVisibleRoot() else { return }
        guard let targetKey = DirectionalNeighborService.findNeighbor(of: currentKey, direction: direction, in: root) else { return }
        TileService.shared.swap(currentKey, targetKey)
        ReapplyHandler.reapplyAll()
    }
}
