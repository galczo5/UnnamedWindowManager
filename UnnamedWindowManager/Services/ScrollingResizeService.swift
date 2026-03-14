import AppKit

// Handles user-initiated resizes of the scrolling center slot.
struct ScrollingResizeService {

    func applyResize(centerKey: WindowSlot, actualWidth: CGFloat, screen: NSScreen) {
        let og = Config.outerGaps
        let screenWidth = screen.visibleFrame.width - og.left! - og.right!
        ScrollingTileService.shared.updateCenterFraction(
            for: centerKey,
            proposedWidth: actualWidth,
            screenWidth: screenWidth,
            screen: screen
        )
    }
}
