//
//  UnsnapHandler.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

struct UnsnapHandler {

    /// Removes the frontmost focused window from the layout and reflows all remaining windows.
    /// Also restores the window's pre-snap visibility state and stops observing its AX notifications.
    static func unsnap() {
        guard AXIsProcessTrusted() else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else { return }
        let axWindow = focusedWindow as! AXUIElement

        guard let screen = NSScreen.main else { return }
        let key = windowSlot(for: axWindow, pid: pid)
        WindowVisibilityManager.shared.restoreAndForget(key)
        SnapService.shared.removeAndReflow(key, screen: screen)
        ResizeObserver.shared.stopObserving(key: key, pid: pid)
        ReapplyHandler.reapplyAll()
    }
}
