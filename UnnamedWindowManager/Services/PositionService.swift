import AppKit

// Computes pixel sizes for all slots given the root dimensions and their fractional shares.
struct PositionService {

    func recomputeSizes(_ root: inout TilingRootSlot, width: CGFloat, height: CGFloat) {
        Logger.shared.log("recomputeSizes(root): \(Int(width))×\(Int(height))")
        root.width = width
        root.height = height
        guard !root.children.isEmpty else { return }
        for i in root.children.indices {
            let cw = root.orientation == .horizontal ? (width * root.children[i].fraction).rounded() : width
            let ch = root.orientation == .horizontal ? height : (height * root.children[i].fraction).rounded()
            recomputeSizes(&root.children[i], width: cw, height: ch)
        }
    }

    func recomputeSizes(_ slot: inout Slot, width: CGFloat, height: CGFloat) {
        Logger.shared.log("recomputeSizes(slot): \(Int(width))×\(Int(height))")
        switch slot {
        case .window(var w):
            w.width = width; w.height = height
            slot = .window(w)
        case .horizontal(var h):
            h.width = width; h.height = height
            guard !h.children.isEmpty else { slot = .horizontal(h); return }
            for i in h.children.indices {
                recomputeSizes(&h.children[i], width: (width * h.children[i].fraction).rounded(), height: height)
            }
            slot = .horizontal(h)
        case .vertical(var v):
            v.width = width; v.height = height
            guard !v.children.isEmpty else { slot = .vertical(v); return }
            for i in v.children.indices {
                recomputeSizes(&v.children[i], width: width, height: (height * v.children[i].fraction).rounded())
            }
            slot = .vertical(v)
        case .stacking(var s):
            s.width = width; s.height = height
            for i in s.children.indices {
                s.children[i].height = height
            }
            slot = .stacking(s)
        }
    }

}
