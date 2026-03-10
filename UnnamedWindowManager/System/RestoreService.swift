import ApplicationServices

/// Restores a window's position and size to its pre-tile frame via the Accessibility API.
struct RestoreService {

    static func restore(_ slot: WindowSlot, element: AXUIElement) {
        guard var pos = slot.preTileOrigin, var size = slot.preTileSize else { return }
        if let posVal = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
        }
    }
}
