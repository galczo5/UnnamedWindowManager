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

        let key = windowSlot(for: axWindow, pid: pid)
        guard !ManagedSlotRegistry.shared.isTracked(key) else { return }

        ManagedSlotRegistry.shared.snap(key, screen: screen)
        ResizeObserver.shared.observe(window: axWindow, pid: pid, key: key)
        reapplyAll()
    }

    static func organize() {
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
            return
        }
        guard let screen = NSScreen.main else { return }
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)

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

        for item in candidates.sorted(by: { $0.originX < $1.originX }) {
            let key = windowSlot(for: item.window, pid: item.pid)
            guard !ManagedSlotRegistry.shared.isTracked(key) else { continue }
            ManagedSlotRegistry.shared.snap(key, screen: screen)
            ResizeObserver.shared.observe(window: item.window, pid: item.pid, key: key)
        }
        reapplyAll()
    }

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
        ManagedSlotRegistry.shared.removeAndReflow(key, screen: screen)
        ResizeObserver.shared.stopObserving(key: key, pid: pid)
        reapplyAll()
    }

    /// Snaps `window` as a new leaf. Skips windows already tracked, minimized, or too small.
    static func snapLeft(window: AXUIElement, pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        guard let screen = NSScreen.main else { return }

        let key = windowSlot(for: window, pid: pid)
        guard !ManagedSlotRegistry.shared.isTracked(key) else { return }

        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
           (minRef as? Bool) == true { return }
        if let sz = readSize(of: window), sz.width < 100 || sz.height < 100 { return }

        ManagedSlotRegistry.shared.snap(key, screen: screen)
        ResizeObserver.shared.observe(window: window, pid: pid, key: key)
        reapplyAll()
    }

    static func reapply(window: AXUIElement, key: WindowSlot) {
        guard ManagedSlotRegistry.shared.isTracked(key) else { return }
        guard let screen = NSScreen.main else { return }
        applyLayout(screen: screen)
    }

    static func reapplyAll() {
        guard let screen = NSScreen.main else { return }
        let leaves = ManagedSlotRegistry.shared.allLeaves()
        let allWindows = Set(leaves.compactMap { leaf -> WindowSlot? in
            if case .window(let w) = leaf { return w }
            return nil
        })
        ResizeObserver.shared.reapplying.formUnion(allWindows)
        applyLayout(screen: screen)
        WindowVisibilityManager.shared.applyVisibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            ResizeObserver.shared.reapplying.subtract(allWindows)
        }
    }

    static func windowSlot(for window: AXUIElement, pid: pid_t) -> WindowSlot {
        let hash = windowID(of: window).map(UInt.init)
                   ?? UInt(bitPattern: Unmanaged.passUnretained(window).toOpaque())
        return WindowSlot(pid: pid, windowHash: hash, id: UUID(), parentId: UUID(), order: 0, width: 0, height: 0)
    }
}
