//
//  WindowSnapper.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

struct WindowSnapper {

    static func snap(_ side: SnapSide) {
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

        applyFrame(to: axWindow, side: side)

        let key = snapKey(for: axWindow, pid: pid)
        SnapRegistry.shared.register(key, side: side)
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
        guard let side = SnapRegistry.shared.side(for: key) else { return }
        applyFrame(to: window, side: side)
    }

    static func snapKey(for window: AXUIElement, pid: pid_t) -> SnapKey {
        let ptr = Unmanaged.passUnretained(window).toOpaque()
        return SnapKey(pid: pid, windowHash: UInt(bitPattern: ptr))
    }

    // MARK: - Private

    private static func applyFrame(to window: AXUIElement, side: SnapSide) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let primaryHeight = NSScreen.screens[0].frame.height

        let gap: CGFloat = 10
        let w = visible.width * 0.4 - gap * 2
        let h = visible.height - gap * 2
        let appKitX: CGFloat = side == .left
            ? visible.minX + gap
            : visible.maxX - visible.width * 0.4 + gap

        let axX = appKitX
        let axY = primaryHeight - visible.maxY + gap

        var origin = CGPoint(x: axX, y: axY)
        var size   = CGSize(width: w, height: h)

        // Set position first, then size (order matters to avoid layout artifacts)
        if let posVal = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        }
    }
}
