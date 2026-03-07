import AppKit
import ApplicationServices

// Reads and flips the orientation of the focused window's parent container.
struct OrientFlipHandler {

    /// Returns the orientation of the direct parent container of the focused tracked window,
    /// or nil if no tracked window is currently focused.
    /// Scans all tracked AX elements directly instead of using the frontmost-app API,
    /// which is unreliable when a menu bar extra menu is open (the menu activates our process).
    static func parentOrientation() -> Orientation? {
        guard let key = focusedTrackedKey() else { return nil }
        return SnapService.shared.parentOrientation(of: key)
    }

    /// Flips the orientation of the focused tracked window's parent container and reapplies layout.
    /// No-op if no tracked window is focused.
    static func flipOrientation() {
        guard AXIsProcessTrusted(), let screen = NSScreen.main else { return }
        guard let key = focusedTrackedKey() else { return }
        SnapService.shared.flipParentOrientation(key, screen: screen)
        ReapplyHandler.reapplyAll()
    }

    // MARK: - Private

    /// Scans all tracked AX windows and returns the key of the one with keyboard focus.
    /// Falls back to the "main" window attribute if no element reports focus
    /// (native menus can capture keyboard focus away from the underlying window).
    private static func focusedTrackedKey() -> WindowSlot? {
        let elements = ResizeObserver.shared.elements
        // Pass 1: look for a window that explicitly has keyboard focus.
        for (key, axWindow) in elements {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXFocusedAttribute as CFString, &ref) == .success,
               ref as? Bool == true {
                return key
            }
        }
        // Pass 2: fall back to whichever tracked window is the main window of its app.
        for (key, axWindow) in elements {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXMainAttribute as CFString, &ref) == .success,
               ref as? Bool == true {
                return key
            }
        }
        return nil
    }
}
