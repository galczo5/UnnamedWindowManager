//
//  AXHelpers.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ outWindowID: UnsafeMutablePointer<CGWindowID>) -> AXError

extension WindowSnapper {

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

    internal static func windowID(of window: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(window, &wid) == .success ? wid : nil
    }

    internal static func readOrigin(of window: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &ref) == .success,
              let axVal = ref,
              CFGetTypeID(axVal) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(axVal as! AXValue, .cgPoint, &point)
        return point
    }
}
