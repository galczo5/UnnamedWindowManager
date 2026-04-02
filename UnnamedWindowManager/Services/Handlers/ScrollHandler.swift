import AppKit
import ApplicationServices

// Entry point for creating or extending the scrolling root from the menu.
struct ScrollHandler {

    /// Scrolls the frontmost window if it is not scrolled, or unscrolls it if it is.
    static func scrollToggle() {
        guard AXIsProcessTrusted() else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else { return }
        let key = windowSlot(for: focusedWindow as! AXUIElement, pid: pid)
        if ScrollingRootStore.shared.isTracked(key) {
            UnscrollHandler.unscroll()
        } else {
            scroll()
        }
    }

    /// Adds `window` to the scrolling root, or creates a new one.
    /// Skips if a tiling root is active, already tracked, minimised, or < 100×100 pts.
    static func scrollWindow(_ window: AXUIElement, pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        guard TilingRootStore.shared.snapshotVisibleRoot() == nil else { return }
        guard let screen = NSScreen.main else { return }

        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
           (minRef as? Bool) == true { return }
        if let sz = readSize(of: window), sz.width < 100 || sz.height < 100 { return }

        var key = windowSlot(for: window, pid: pid)
        guard !ScrollingRootStore.shared.isTracked(key) else { return }
        key.preTileOrigin = readOrigin(of: window)
        key.preTileSize   = readSize(of: window)

        if ScrollingRootStore.shared.snapshotVisibleScrollingRoot() != nil {
            ScrollingRootStore.shared.addWindow(key, screen: screen)
        } else {
            ScrollingRootStore.shared.createScrollingRoot(key: key, screen: screen)
        }
        ResizeObserver.shared.observe(window: window, pid: pid, key: key)
        ReapplyHandler.reapplyAll()
    }

    /// Creates a scrolling root with the focused window in center, or adds the focused
    /// window to an existing scrolling root. No-op if a tiling root is active.
    static func scroll() {
        guard AXIsProcessTrusted() else { return }
        guard TilingRootStore.shared.snapshotVisibleRoot() == nil else { return }

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

        if ScrollingRootStore.shared.snapshotVisibleScrollingRoot() != nil {
            ScrollingRootStore.shared.addWindow(key, screen: screen)
        } else {
            ScrollingRootStore.shared.createScrollingRoot(key: key, screen: screen)
        }
        ResizeObserver.shared.observe(window: axWindow, pid: pid, key: key)
        ReapplyHandler.reapplyAll()
    }
}
