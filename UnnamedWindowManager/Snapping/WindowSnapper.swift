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
