import AppKit
import ApplicationServices

// Entry point for creating or extending the scrolling root from the menu.
struct ScrollingRootHandler {

    /// Creates a scrolling root with the focused window in center, or adds the focused
    /// window to an existing scrolling root. No-op if a tiling root is active.
    static func scroll() {
        guard AXIsProcessTrusted() else { return }
        guard TileService.shared.snapshotVisibleRoot() == nil else { return }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString,
                                            &focusedWindow) == .success else { return }
        let axWindow = focusedWindow as! AXUIElement
        guard let screen = NSScreen.main else { return }

        var key = windowSlot(for: axWindow, pid: pid)
        key.preTileOrigin = readOrigin(of: axWindow)
        key.preTileSize   = readSize(of: axWindow)

        if ScrollingTileService.shared.snapshotVisibleScrollingRoot() != nil {
            ScrollingTileService.shared.addWindow(key, screen: screen)
        } else {
            ScrollingTileService.shared.createScrollingRoot(key: key, screen: screen)
        }
        ResizeObserver.shared.observe(window: axWindow, pid: pid, key: key)
        ReapplyHandler.reapplyAll()
    }
}
