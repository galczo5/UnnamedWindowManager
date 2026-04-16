import ApplicationServices

/// Restores a window's position and size to its pre-tile frame via the Accessibility API.
struct WindowRestoreService {

    static func restore(_ slot: WindowSlot, element: AXUIElement) {
        guard let pos = slot.preTileOrigin, let size = slot.preTileSize else { return }
        Logger.shared.log("restore wid=\(slot.windowHash) pid=\(slot.pid) pos=(\(Int(pos.x)),\(Int(pos.y))) size=\(Int(size.width))x\(Int(size.height))")
        var p = pos
        if let posVal = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
        }
        var s = size
        if let sizeVal = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
        }
    }
}
