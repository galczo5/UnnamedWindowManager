import CoreGraphics

// Computes pixel dimensions for all zones of a ScrollingRootSlot.
// Center width is determined by centerWidthFraction (default 0.8); left and right split the remaining width.
struct ScrollingPositionService {

    // When updateSideWindowWidths is false, only slot boundaries (s.size.width) are updated for side slots —
    // window widths inside them are left unchanged. Used during center-only resize so side windows
    // keep their rendered size while their position is still recalculated correctly.
    func recomputeSizes(_ root: inout ScrollingRootSlot, width: CGFloat, height: CGFloat,
                        updateSideWindowWidths: Bool = true) {
        root.size = CGSize(width: width, height: height)
        let fraction    = root.centerWidthFraction ?? Config.scrollCenterDefaultWidthFraction
        let centerWidth = (width * fraction).rounded()
        let remaining   = width - centerWidth
        let bothSides   = root.left != nil && root.right != nil
        let sideWidth   = (bothSides ? remaining / 2 : remaining).rounded()

        if root.left  != nil { setSideSizes(&root.left!,  slotWidth: sideWidth, windowWidth: updateSideWindowWidths ? centerWidth : nil, height: height) }
        setSizes(&root.center,                             width: centerWidth, height: height)
        if root.right != nil { setSideSizes(&root.right!, slotWidth: sideWidth, windowWidth: updateSideWindowWidths ? centerWidth : nil, height: height) }
    }

    // Clamps a proposed center pixel width to [35%, 90%] of screenWidth and returns the fraction.
    static func clampedCenterFraction(proposedWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {
        let minWidth = (screenWidth * 0.35).rounded()
        let maxWidth = (screenWidth * 0.90).rounded()
        return min(maxWidth, max(minWidth, proposedWidth)) / screenWidth
    }

    // Sets the slot boundary to slotWidth and (if windowWidth is non-nil) each window inside to windowWidth.
    // Used for side zones where windows are wider than their slot (they peek behind center).
    private func setSideSizes(_ slot: inout Slot, slotWidth: CGFloat, windowWidth: CGFloat?, height: CGFloat) {
        switch slot {
        case .window(var w):
            if let ww = windowWidth { w.size.width = ww }
            w.size.height = height
            slot = .window(w)
        case .stacking(var s):
            s.size = CGSize(width: slotWidth, height: height)
            if let ww = windowWidth {
                for i in s.children.indices { s.children[i].size = CGSize(width: ww, height: height) }
            }
            slot = .stacking(s)
        default:
            break
        }
    }

    private func setSizes(_ slot: inout Slot, width: CGFloat, height: CGFloat) {
        switch slot {
        case .window(var w):
            w.size = CGSize(width: width, height: height)
            slot = .window(w)
        case .stacking(var s):
            s.size = CGSize(width: width, height: height)
            for i in s.children.indices { s.children[i].size = CGSize(width: width, height: height) }
            slot = .stacking(s)
        default:
            break
        }
    }
}
