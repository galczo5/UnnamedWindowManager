import AppKit

// Screen geometry utilities: usable tiling area and AX coordinate origin.
func screenTilingArea(_ screen: NSScreen) -> CGSize {
    let og = Config.outerGaps
    return CGSize(
        width:  screen.visibleFrame.width  - og.left! - og.right!,
        height: screen.visibleFrame.height - og.top!  - og.bottom!
    )
}

func screenLayoutOrigin(_ screen: NSScreen) -> CGPoint {
    let visible = screen.visibleFrame
    let primaryHeight = NSScreen.screens[0].frame.height
    let og = Config.outerGaps
    return CGPoint(x: visible.minX + og.left!, y: primaryHeight - visible.maxY + og.top!)
}
