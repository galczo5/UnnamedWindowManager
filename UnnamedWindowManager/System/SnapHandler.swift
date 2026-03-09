import AppKit
import ApplicationServices

// Entry point for snapping the focused window into the layout.
struct SnapHandler {

    /// Snaps the frontmost focused window into the layout.
    /// Prompts for AX trust if not yet granted. No-op if the window is already tracked.
    static func snap() {
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
            return
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else { return }
        let axWindow = focusedWindow as! AXUIElement

        guard let screen = NSScreen.main else { return }
        var key = windowSlot(for: axWindow, pid: pid)
        key.preSnapOrigin = readOrigin(of: axWindow)
        key.preSnapSize = readSize(of: axWindow)
        Logger.shared.log("snap: pid=\(pid) hash=\(key.windowHash)")
        SnapService.shared.snap(key, screen: screen)
        ResizeObserver.shared.observe(window: axWindow, pid: pid, key: key)
        ReapplyHandler.reapplyAll()
    }

    /// Snaps `window` into the layout as a new leaf.
    /// Skips windows that are already tracked, minimised, or smaller than 100×100 pts.
    static func snapLeft(window: AXUIElement, pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        guard let screen = NSScreen.main else { return }

        var key = windowSlot(for: window, pid: pid)
        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
           (minRef as? Bool) == true { return }
        if let sz = readSize(of: window), sz.width < 100 || sz.height < 100 { return }

        key.preSnapOrigin = readOrigin(of: window)
        key.preSnapSize = readSize(of: window)
        Logger.shared.log("snapLeft: pid=\(pid) hash=\(key.windowHash)")
        SnapService.shared.snap(key, screen: screen)
        ResizeObserver.shared.observe(window: window, pid: pid, key: key)
        ReapplyHandler.reapplyAll()
    }
}
