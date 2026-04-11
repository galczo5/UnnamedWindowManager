import AppKit
import ApplicationServices

// Entry points for removing windows from the layout.
struct UntileHandler {

    /// Removes the frontmost focused window from the layout and reflows all remaining windows.
    /// Also restores the window's pre-tile visibility state and stops observing its AX notifications.
    static func untile() {
        guard AXIsProcessTrusted() else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else { return }
        let axWindow = focusedWindow as! AXUIElement

        guard let screen = NSScreen.main else { return }
        let key = windowSlot(for: axWindow, pid: pid)
        let stored = TilingRootStore.shared.storedSlot(key)
        FocusedWindowBorderService.shared.hideIfActive(key: key)
        WindowOpacityService.shared.restore(hash: key.windowHash)
        TilingService.shared.removeAndReflow(key, screen: screen)
        WindowEventRouter.shared.stopObserving(key: key, pid: pid)
        if let stored { WindowRestoreService.restore(stored, element: axWindow) }
        ReapplyHandler.reapplyAll()
    }

    static func untileAll() {
        guard AXIsProcessTrusted() else { return }
        let elements = WindowTracker.shared.elements
        let removed = TilingService.shared.removeVisibleRoot()
        WindowOpacityService.shared.restoreAll()
        FocusedWindowBorderService.shared.hide()
        for key in removed {
            if let ax = elements[key] { WindowRestoreService.restore(key, element: ax) }
            WindowEventRouter.shared.stopObserving(key: key, pid: key.pid)
        }
        TileStateChangedObserver.shared.notify(TileStateChangedEvent())
    }

    static func untileByKey(_ key: WindowSlot, screen: NSScreen) {
        let isScrolling = ScrollingRootStore.shared.isTracked(key)
        WindowOpacityService.shared.restore(hash: key.windowHash)
        if let ax = WindowTracker.shared.elements[key] {
            WindowRestoreService.restore(key, element: ax)
        }
        if isScrolling {
            ScrollingRootStore.shared.removeWindow(key, screen: screen)
        } else {
            TilingService.shared.removeAndReflow(key, screen: screen)
        }
        WindowEventRouter.shared.stopObserving(key: key, pid: key.pid)
    }

    static func untileAllSpaces() {
        guard AXIsProcessTrusted() else { return }
        let elements = WindowTracker.shared.elements
        let removed = TilingService.shared.removeAllTilingRoots()
        WindowOpacityService.shared.restoreAll()
        FocusedWindowBorderService.shared.hide()
        for key in removed {
            if let ax = elements[key] { WindowRestoreService.restore(key, element: ax) }
            WindowEventRouter.shared.stopObserving(key: key, pid: key.pid)
        }
    }
}
