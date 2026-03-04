//
//  WindowVisibilityManager.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

final class WindowVisibilityManager {
    static let shared = WindowVisibilityManager()
    private init() {}

    /// Windows minimized automatically because their slot is off-screen.
    private var autoMinimized: Set<ManagedWindow> = []

    /// Call after every reapplyAll(). Minimizes windows in off-screen slots;
    /// restores windows whose slots have come back on-screen.
    func applyVisibility(slots: [ManagedSlot]) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame

        var xOffset = visible.minX + Config.gap
        for (si, slot) in slots.enumerated() {
            let isOffScreen = xOffset >= visible.maxX
            if slot.hidden != isOffScreen {
                ManagedSlotRegistry.shared.setHidden(isOffScreen, forSlotAt: si)
            }
            for win in slot.windows {
                guard let axWindow = ResizeObserver.shared.window(for: win) else { continue }
                if isOffScreen {
                    if !autoMinimized.contains(win) {
                        setMinimized(true, window: axWindow)
                        autoMinimized.insert(win)
                    }
                } else {
                    if autoMinimized.contains(win) {
                        setMinimized(false, window: axWindow)
                        WindowSnapper.applyPosition(to: axWindow, key: win, slots: slots)
                        autoMinimized.remove(win)
                    }
                }
            }
            xOffset += slot.width + Config.gap
        }
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
    /// Call from the destroy handler after the AX element is no longer valid.
    func windowRemoved(_ key: ManagedWindow) {
        autoMinimized.remove(key)
    }

    private func setMinimized(_ minimized: Bool, window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, minimized as CFBoolean)
    }
}
