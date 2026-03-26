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
        WindowOpacityService.shared.restore(hash: key.windowHash)
        WindowVisibilityManager.shared.restoreAndForget(key)
        TilingSnapService.shared.removeAndReflow(key, screen: screen)
        ResizeObserver.shared.stopObserving(key: key, pid: pid)
        if let stored { RestoreService.restore(stored, element: axWindow) }
        ReapplyHandler.reapplyAll()
    }

    static func untileAll() {
        guard AXIsProcessTrusted() else { return }
        let elements = ResizeObserver.shared.elements
        let removed = TilingSnapService.shared.removeVisibleRoot()
        WindowOpacityService.shared.restoreAll()
        for key in removed {
            if let ax = elements[key] { RestoreService.restore(key, element: ax) }
            WindowVisibilityManager.shared.restoreAndForget(key)
            ResizeObserver.shared.stopObserving(key: key, pid: key.pid)
        }
        NotificationCenter.default.post(name: .tileStateChanged, object: nil)
    }

    static func untileByKey(_ key: WindowSlot, screen: NSScreen) {
        let isScrolling = ScrollingRootStore.shared.isTracked(key)
        WindowOpacityService.shared.restore(hash: key.windowHash)
        WindowVisibilityManager.shared.restoreAndForget(key)
        if let ax = ResizeObserver.shared.elements[key] {
            RestoreService.restore(key, element: ax)
        }
        if isScrolling {
            ScrollingRootStore.shared.removeWindow(key, screen: screen)
        } else {
            TilingSnapService.shared.removeAndReflow(key, screen: screen)
        }
        ResizeObserver.shared.stopObserving(key: key, pid: key.pid)
    }

    static func untileAllSpaces() {
        guard AXIsProcessTrusted() else { return }
        let elements = ResizeObserver.shared.elements
        let removed = TilingSnapService.shared.removeAllTilingRoots()
        WindowOpacityService.shared.restoreAll()
        for key in removed {
            if let ax = elements[key] { RestoreService.restore(key, element: ax) }
            WindowVisibilityManager.shared.restoreAndForget(key)
            ResizeObserver.shared.stopObserving(key: key, pid: key.pid)
        }
    }
}
