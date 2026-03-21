import AppKit

/// Returns the usable tiling area after subtracting outer gaps from the screen's visible frame.
func screenTilingArea(_ screen: NSScreen) -> CGSize {
    let og = Config.outerGaps
    return CGSize(
        width:  screen.visibleFrame.width  - og.left! - og.right!,
        height: screen.visibleFrame.height - og.top!  - og.bottom!
    )
}
