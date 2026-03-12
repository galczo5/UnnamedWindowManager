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
        Logger.shared.log("applyVisibility: autoMinimized=\(autoMinimized.count)")
        for key in autoMinimized {
            if let axWindow = ResizeObserver.shared.window(for: key) {
                setMinimized(false, window: axWindow)
            }
        }
        autoMinimized.removeAll()
    }

    /// Restores a window if it was auto-minimized, then removes it from tracking.
    /// Call before releasing a window from the registry (e.g. untile).
    func restoreAndForget(_ key: WindowSlot) {
        Logger.shared.log("restoreAndForget: hash=\(key.windowHash)")
        guard autoMinimized.contains(key) else {
            Logger.shared.log("restoreAndForget: not auto-minimized, skipping")
            return
        }
        if let axWindow = ResizeObserver.shared.window(for: key) {
            setMinimized(false, window: axWindow)
        }
        autoMinimized.remove(key)
    }

    /// Removes a closed window from the tracking set without attempting to restore it.
    func windowRemoved(_ key: WindowSlot) {
        Logger.shared.log("windowRemoved: hash=\(key.windowHash)")
        autoMinimized.remove(key)
    }

    private func setMinimized(_ minimized: Bool, window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, minimized as CFBoolean)
    }
}
