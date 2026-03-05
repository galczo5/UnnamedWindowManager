//
//  PositionService.swift
//  UnnamedWindowManager
//

import AppKit

struct PositionService {

    func recomputeSizes(_ root: inout RootSlot, width: CGFloat, height: CGFloat) {
        root.width = width
        root.height = height
        guard !root.children.isEmpty else { return }
        let n = CGFloat(root.children.count)
        let cw = root.orientation == .horizontal ? width / n : width
        let ch = root.orientation == .horizontal ? height : height / n
        for i in root.children.indices {
            recomputeSizes(&root.children[i], width: cw, height: ch)
        }
    }

    func recomputeSizes(_ slot: inout Slot, width: CGFloat, height: CGFloat) {
        switch slot {
        case .window(var w):
            w.width = width; w.height = height
            slot = .window(w)
        case .horizontal(var h):
            h.width = width; h.height = height
            let n = CGFloat(h.children.count)
            guard n > 0 else { slot = .horizontal(h); return }
            for i in h.children.indices {
                recomputeSizes(&h.children[i], width: width / n, height: height)
            }
            slot = .horizontal(h)
        case .vertical(var v):
            v.width = width; v.height = height
            let n = CGFloat(v.children.count)
            guard n > 0 else { slot = .vertical(v); return }
            for i in v.children.indices {
                recomputeSizes(&v.children[i], width: width, height: height / n)
            }
            slot = .vertical(v)
        }
    }

    func clampedWidth(_ width: CGFloat, screen: NSScreen) -> CGFloat {
        min(width, screen.visibleFrame.width * Config.maxWidthFraction)
    }
}
