import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ outWindowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Returns the rendered size of `window`, or nil if the AX attribute is unavailable or zero.
func readSize(of window: AXUIElement) -> CGSize? {
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let axVal = sizeRef,
          CFGetTypeID(axVal) == AXValueGetTypeID()
    else { return nil }
    var size = CGSize.zero
    AXValueGetValue(axVal as! AXValue, .cgSize, &size)
    return (size.width > 0 && size.height > 0) ? size : nil
}

/// Returns the CGWindowID of `window` via the private AX SPI, or nil on failure.
func windowID(of window: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    return _AXUIElementGetWindow(window, &wid) == .success ? wid : nil
}

/// Returns the top-left origin of `window` in AX coordinates (top-left screen origin), or nil on failure.
func readOrigin(of window: AXUIElement) -> CGPoint? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &ref) == .success,
          let axVal = ref,
          CFGetTypeID(axVal) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    AXValueGetValue(axVal as! AXValue, .cgPoint, &point)
    return point
}

/// Returns the AXUIElement for the window with the given CGWindowID hash, or nil.
func axWindow(forHash hash: UInt, pid: pid_t) -> AXUIElement? {
    let axApp = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let axWindows = windowsRef as? [AXUIElement] else { return nil }
    return axWindows.first { windowID(of: $0).map(UInt.init) == hash }
}

/// Builds a `WindowSlot` identity key from an AX window element and its owning pid.
/// Uses the CGWindowID when available; falls back to the AXUIElement pointer address.
func windowSlot(for window: AXUIElement, pid: pid_t) -> WindowSlot {
    let hash = windowID(of: window).map(UInt.init)
               ?? UInt(bitPattern: Unmanaged.passUnretained(window).toOpaque())
    return WindowSlot(pid: pid, windowHash: hash, id: UUID(), parentId: UUID(), order: 0, size: .zero)
}
