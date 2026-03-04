//
//  WindowVisibilityManager.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

final class WindowVisibilityManager {
    static let shared = WindowVisibilityManager()
    private init() {}

    private var autoMinimized: Set<ManagedWindow> = []

    /// Called after every `reapplyAll()`. With the tree layout all leaves fit on screen,
    /// so any previously auto-minimized windows are restored.
    func applyVisibility() {
        for key in autoMinimized {
            if let axWindow = ResizeObserver.shared.window(for: key) {
                setMinimized(false, window: axWindow)
            }
        }
        autoMinimized.removeAll()
    }

    /// Restores a window if it was auto-minimized, then removes it from tracking.
    /// Call before releasing a window from the registry (e.g. unsnap).
    func restoreAndForget(_ key: ManagedWindow) {
        guard autoMinimized.contains(key) else { return }
        if let axWindow = ResizeObserver.shared.window(for: key) {
            setMinimized(false, window: axWindow)
        }
        autoMinimized.remove(key)
    }

    /// Removes a closed window from the tracking set without attempting to restore it.
    func windowRemoved(_ key: ManagedWindow) {
        autoMinimized.remove(key)
    }

    private func setMinimized(_ minimized: Bool, window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, minimized as CFBoolean)
    }
}
