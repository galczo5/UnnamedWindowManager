import AppKit

// Computes pixel sizes for all slots given the root dimensions and their fractional shares.
struct TilingPositionService {

    func recomputeSizes(_ root: inout TilingRootSlot, width: CGFloat, height: CGFloat) {
        root.size = CGSize(width: width, height: height)
        guard !root.children.isEmpty else { return }
        for i in root.children.indices {
            let cw = root.orientation == .horizontal ? (width * root.children[i].fraction).rounded() : width
            let ch = root.orientation == .horizontal ? height : (height * root.children[i].fraction).rounded()
            recomputeSizes(&root.children[i], width: cw, height: ch)
        }
    }

    func recomputeSizes(_ slot: inout Slot, width: CGFloat, height: CGFloat) {
        switch slot {
        case .window(var w):
            w.size = CGSize(width: width, height: height)
            slot = .window(w)
        case .split(var s):
            s.size = CGSize(width: width, height: height)
            guard !s.children.isEmpty else { slot = .split(s); return }
            for i in s.children.indices {
                let cw = s.orientation == .horizontal ? (width * s.children[i].fraction).rounded() : width
                let ch = s.orientation == .horizontal ? height : (height * s.children[i].fraction).rounded()
                recomputeSizes(&s.children[i], width: cw, height: ch)
            }
            slot = .split(s)
        case .stacking(var s):
            s.size = CGSize(width: width, height: height)
            for i in s.children.indices {
                s.children[i].size.height = height
            }
            slot = .stacking(s)
        }
    }

}
