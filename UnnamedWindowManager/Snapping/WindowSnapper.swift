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

        let key  = snapKey(for: axWindow, pid: pid)
        let slot = SnapRegistry.shared.nextSlot()
        SnapRegistry.shared.register(key, slot: slot, width: clamped.width, height: clamped.height)
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
            let key = snapKey(for: item.window, pid: item.pid)
            guard !SnapRegistry.shared.isTracked(key) else { continue }
            let rawSize = CGSize(
                width:  readSize(of: item.window)?.width ?? visible.width * Config.fallbackWidthFraction,
                height: visible.height - Config.gap * 2
            )
            let clamped = clampSize(rawSize, screen: screen)
            let slot = SnapRegistry.shared.nextSlot()
            SnapRegistry.shared.register(key, slot: slot, width: clamped.width, height: clamped.height)
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

        let key = snapKey(for: axWindow, pid: pid)
        SnapRegistry.shared.remove(key)
        ResizeObserver.shared.stopObserving(key: key, pid: pid)
    }

    static func reapply(window: AXUIElement, key: SnapKey) {
        guard SnapRegistry.shared.entry(for: key) != nil else { return }
        applyPosition(to: window, key: key)
    }

    static func reapplyAll() {
        let entries = SnapRegistry.shared.allEntries()
        for (key, _) in entries {
            guard let axWindow = ResizeObserver.shared.window(for: key) else { continue }
            applyPosition(to: axWindow, key: key, entries: entries)
        }
    }

    static func snapKey(for window: AXUIElement, pid: pid_t) -> SnapKey {
        let hash = windowID(of: window).map(UInt.init)
                   ?? UInt(bitPattern: Unmanaged.passUnretained(window).toOpaque())
        return SnapKey(pid: pid, windowHash: hash)
    }
}
