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

        let visible = NSScreen.main?.visibleFrame ?? .zero
        let snapHeight = visible.height - Config.gap * 2
        let originalWidth = readSize(of: axWindow)?.width ?? visible.width * Config.fallbackWidthFraction

        let key  = snapKey(for: axWindow, pid: pid)
        let slot = SnapRegistry.shared.nextSlot()
        SnapRegistry.shared.register(key, slot: slot, width: originalWidth, height: snapHeight)
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
        let ptr = Unmanaged.passUnretained(window).toOpaque()
        return SnapKey(pid: pid, windowHash: UInt(bitPattern: ptr))
    }

    internal static func readSize(of window: AXUIElement) -> CGSize? {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let axVal = sizeRef,
              CFGetTypeID(axVal) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        AXValueGetValue(axVal as! AXValue, .cgSize, &size)
        return (size.width > 0 && size.height > 0) ? size : nil
    }

    // MARK: - Private

    private static func applyPosition(
        to window: AXUIElement,
        key: SnapKey,
        entries: [(key: SnapKey, entry: SnapEntry)]? = nil
    ) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let primaryHeight = NSScreen.screens[0].frame.height

        let allEntries = entries ?? SnapRegistry.shared.allEntries()
        guard let myEntry = allEntries.first(where: { $0.key == key })?.entry else { return }

        // Sum widths of all windows in lower slots to compute this window's X position.
        var xOffset = visible.minX + Config.gap
        for item in allEntries {
            if item.entry.slot == myEntry.slot { break }
            xOffset += item.entry.width + Config.gap
        }

        let axY = primaryHeight - visible.maxY + Config.gap

        var origin = CGPoint(x: xOffset, y: axY)
        var size   = CGSize(width: myEntry.width, height: myEntry.height)

        if let posVal = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        }
    }
}
