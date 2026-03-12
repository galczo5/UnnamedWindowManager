import CoreGraphics

// Computes pixel dimensions for all zones of a ScrollingRootSlot.
// Center is always 80% of the available width; left and right split the remaining 20%.
struct ScrollingPositionService {
    private let centerFraction: CGFloat = 0.8

    func recomputeSizes(_ root: inout ScrollingRootSlot, width: CGFloat, height: CGFloat) {
        Logger.shared.log("recomputeSizes: \(Int(width))×\(Int(height))")
        root.width  = width
        root.height = height
        let centerWidth = (width * centerFraction).rounded()
        let remaining   = width - centerWidth
        let bothSides   = root.left != nil && root.right != nil
        let sideWidth   = (bothSides ? remaining / 2 : remaining).rounded()

        if root.left  != nil { setSideSizes(&root.left!,  slotWidth: sideWidth, windowWidth: centerWidth, height: height) }
        setSizes(&root.center,                             width: centerWidth, height: height)
        if root.right != nil { setSideSizes(&root.right!, slotWidth: sideWidth, windowWidth: centerWidth, height: height) }
    }

    // Sets the slot boundary to slotWidth and each window inside to windowWidth.
    // Used for side zones where windows are wider than their slot (they peek behind center).
    private func setSideSizes(_ slot: inout Slot, slotWidth: CGFloat, windowWidth: CGFloat, height: CGFloat) {
        switch slot {
        case .window(var w):
            w.width = windowWidth; w.height = height
            slot = .window(w)
        case .stacking(var s):
            s.width = slotWidth; s.height = height
            for i in s.children.indices { s.children[i].width = windowWidth; s.children[i].height = height }
            slot = .stacking(s)
        default:
            break
        }
    }

    private func setSizes(_ slot: inout Slot, width: CGFloat, height: CGFloat) {
        switch slot {
        case .window(var w):
            w.width = width; w.height = height
            slot = .window(w)
        case .stacking(var s):
            s.width = width; s.height = height
            for i in s.children.indices { s.children[i].width = width; s.children[i].height = height }
            slot = .stacking(s)
        default:
            break
        }
    }
}
