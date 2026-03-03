//
//  WindowSnapper.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

struct WindowSnapper {

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
        let visible = screen.visibleFrame
        let rawSize = CGSize(
            width:  readSize(of: axWindow)?.width ?? visible.width * Config.fallbackWidthFraction,
            height: visible.height - Config.gap * 2
        )
        let clamped = WindowSnapper.clampSize(rawSize, screen: screen)

        let key = managedWindow(for: axWindow, pid: pid)
        ManagedSlotRegistry.shared.register(key, width: clamped.width, height: clamped.height)
        applyPosition(to: axWindow, key: key)
        ResizeObserver.shared.observe(window: axWindow, pid: pid, key: key)
    }

    static func organize() {
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
            return
        }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)

        // 1. Collect on-screen normal windows (layer 0, minimum size) grouped by PID.
        guard let cgList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        var pidToWindowIDs: [pid_t: Set<CGWindowID>] = [:]
        for info in cgList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid   = info[kCGWindowOwnerPID as String] as? Int,
                  let wid   = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w > 100, h > 100,
                  pid_t(pid) != ownPID
            else { continue }
            pidToWindowIDs[pid_t(pid), default: []].insert(wid)
        }

        // 2. Resolve CGWindowIDs back to AXUIElements; collect origin for ordering.
        var candidates: [(window: AXUIElement, pid: pid_t, originX: CGFloat)] = []
        for (pid, wids) in pidToWindowIDs {
            let axApp = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement] else { continue }
            for axWindow in axWindows {
                guard let wid = windowID(of: axWindow), wids.contains(wid) else { continue }
                var minRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minRef) == .success,
                   (minRef as? Bool) == true { continue }
                let originX = readOrigin(of: axWindow)?.x ?? 0
                candidates.append((window: axWindow, pid: pid, originX: originX))
            }
        }

        // 3. Snap in left-to-right order, skipping already-snapped windows.
        for item in candidates.sorted(by: { $0.originX < $1.originX }) {
            let key = managedWindow(for: item.window, pid: item.pid)
            guard !ManagedSlotRegistry.shared.isTracked(key) else { continue }
            let rawSize = CGSize(
                width:  readSize(of: item.window)?.width ?? visible.width * Config.fallbackWidthFraction,
                height: visible.height - Config.gap * 2
            )
            let clamped = clampSize(rawSize, screen: screen)
            ManagedSlotRegistry.shared.register(key, width: clamped.width, height: clamped.height)
            applyPosition(to: item.window, key: key)
            ResizeObserver.shared.observe(window: item.window, pid: item.pid, key: key)
        }
    }

    static func unsnap() {
        guard AXIsProcessTrusted() else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else { return }
        let axWindow = focusedWindow as! AXUIElement

        let key = managedWindow(for: axWindow, pid: pid)
        ManagedSlotRegistry.shared.remove(key)
        ResizeObserver.shared.stopObserving(key: key, pid: pid)
    }

    /// Snaps `window` as a new slot at position 0 (leftmost).
    /// Skips windows that are already tracked, minimized, or too small.
    static func snapLeft(window: AXUIElement, pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        guard let screen = NSScreen.main else { return }

        let key = managedWindow(for: window, pid: pid)
        guard !ManagedSlotRegistry.shared.isTracked(key) else { return }

        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
           (minRef as? Bool) == true { return }

        if let sz = readSize(of: window), sz.width < 100 || sz.height < 100 { return }

        let visible = screen.visibleFrame
        let rawSize = CGSize(
            width:  readSize(of: window)?.width ?? visible.width * Config.fallbackWidthFraction,
            height: visible.height - Config.gap * 2
        )
        let clamped = clampSize(rawSize, screen: screen)

        ManagedSlotRegistry.shared.registerFirst(key, width: clamped.width, height: clamped.height)
        applyPosition(to: window, key: key)
        ResizeObserver.shared.observe(window: window, pid: pid, key: key)
        reapplyAll()
    }

    static func reapply(window: AXUIElement, key: ManagedWindow) {
        guard ManagedSlotRegistry.shared.isTracked(key) else { return }
        applyPosition(to: window, key: key)
    }

    static func reapplyAll() {
        let slots = ManagedSlotRegistry.shared.allSlots()
        for slot in slots {
            for win in slot.windows {
                guard let axWindow = ResizeObserver.shared.window(for: win) else { continue }
                applyPosition(to: axWindow, key: win, slots: slots)
            }
        }
    }

    static func managedWindow(for window: AXUIElement, pid: pid_t) -> ManagedWindow {
        let hash = windowID(of: window).map(UInt.init)
                   ?? UInt(bitPattern: Unmanaged.passUnretained(window).toOpaque())
        return ManagedWindow(pid: pid, windowHash: hash, height: 0)
    }
}
