//
//  WindowSnapper.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

struct WindowSnapper {
    enum Side { case left, right }

    static func snap(_ side: Side) {
        // Request Accessibility permission if not yet granted
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
            return
        }

        // Get the focused window of the frontmost app
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else { return }
        let axWindow = focusedWindow as! AXUIElement

        // Calculate target frame using the visible area (excludes menu bar + Dock)
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let primaryHeight = NSScreen.screens[0].frame.height

        let gap: CGFloat = 10
        let w = visible.width * 0.4 - gap * 2
        let h = visible.height - gap * 2
        let appKitX: CGFloat = side == .left
            ? visible.minX + gap
            : visible.maxX - visible.width * 0.4 + gap

        // AX uses flipped coordinates (top-left origin); convert from AppKit (bottom-left origin)
        let axX = appKitX
        let axY = primaryHeight - visible.maxY + gap

        // Set position first, then size (order matters to avoid layout artifacts)
        var origin = CGPoint(x: axX, y: axY)
        var size   = CGSize(width: w, height: h)

        if let posVal = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal)
        }
    }
}
