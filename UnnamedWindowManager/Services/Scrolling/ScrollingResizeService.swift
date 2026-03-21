import AppKit

// Handles user-initiated resizes of the scrolling center slot.
struct ScrollingResizeService {

    func applyResize(centerKey: WindowSlot, actualWidth: CGFloat, screen: NSScreen) {
        let screenWidth = screenTilingArea(screen).width
        ScrollingTileService.shared.updateCenterFraction(
            for: centerKey,
            proposedWidth: actualWidth,
            screenWidth: screenWidth,
            screen: screen
        )
    }
}
