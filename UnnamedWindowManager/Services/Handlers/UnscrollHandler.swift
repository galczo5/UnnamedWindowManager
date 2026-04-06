import AppKit
import ApplicationServices

// Entry points for removing windows from the scrolling layout.
struct UnscrollHandler {

    static func unscroll() {
        guard AXIsProcessTrusted() else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else { return }
        let axWindow = focusedWindow as! AXUIElement

        guard let screen = NSScreen.main else { return }
        let key = windowSlot(for: axWindow, pid: pid)
        let stored = ScrollingRootStore.shared.removeWindow(key, screen: screen)
        WindowOpacityService.shared.restore(hash: key.windowHash)
        WindowEventRouter.shared.stopObserving(key: key, pid: pid)
        if let stored { RestoreService.restore(stored, element: axWindow) }
        ReapplyHandler.reapplyAll()
        TileStateChangedObserver.shared.notify(TileStateChangedEvent())
    }

    static func unscrollAll() {
        guard AXIsProcessTrusted() else { return }
        let elements = WindowTracker.shared.elements
        let removed = ScrollingRootStore.shared.removeVisibleScrollingRoot()
        WindowOpacityService.shared.restoreAll()
        for key in removed {
            if let ax = elements[key] { RestoreService.restore(key, element: ax) }
            WindowEventRouter.shared.stopObserving(key: key, pid: key.pid)
        }
        TileStateChangedObserver.shared.notify(TileStateChangedEvent())
    }

    static func unscrollAllSpaces() {
        guard AXIsProcessTrusted() else { return }
        let elements = WindowTracker.shared.elements
        let removed = ScrollingRootStore.shared.removeAllScrollingRoots()
        WindowOpacityService.shared.restoreAll()
        for key in removed {
            if let ax = elements[key] { RestoreService.restore(key, element: ax) }
            WindowEventRouter.shared.stopObserving(key: key, pid: key.pid)
        }
    }
}
