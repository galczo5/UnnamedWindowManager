import AppKit
import ApplicationServices

// Manages auto-minimization state for tiled windows, restoring them when the layout changes.
final class WindowVisibilityManager {
    static let shared = WindowVisibilityManager()
    private init() {}

    private var autoMinimized: Set<WindowSlot> = []

    /// Called after every `reapplyAll()`. With the tree layout all leaves fit on screen,
    /// so any previously auto-minimized windows are restored.
    func applyVisibility() {
        for key in autoMinimized {
            if let axWindow = WindowTracker.shared.window(for: key) {
                setMinimized(false, window: axWindow)
            }
        }
        autoMinimized.removeAll()
    }

    /// Restores a window if it was auto-minimized, then removes it from tracking.
    /// Call before releasing a window from the registry (e.g. untile).
    func restoreAndForget(_ key: WindowSlot) {
        guard autoMinimized.contains(key) else {
            return
        }
        if let axWindow = WindowTracker.shared.window(for: key) {
            setMinimized(false, window: axWindow)
        }
        autoMinimized.remove(key)
    }

    /// Removes a closed window from the tracking set without attempting to restore it.
    func windowRemoved(_ key: WindowSlot) {
        autoMinimized.remove(key)
    }

    private func setMinimized(_ minimized: Bool, window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, minimized as CFBoolean)
    }
}
