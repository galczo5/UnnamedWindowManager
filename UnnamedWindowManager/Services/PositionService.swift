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
        for i in root.children.indices {
            let cw = root.orientation == .horizontal ? width * root.children[i].fraction : width
            let ch = root.orientation == .horizontal ? height : height * root.children[i].fraction
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
            guard !h.children.isEmpty else { slot = .horizontal(h); return }
            for i in h.children.indices {
                recomputeSizes(&h.children[i], width: width * h.children[i].fraction, height: height)
            }
            slot = .horizontal(h)
        case .vertical(var v):
            v.width = width; v.height = height
            guard !v.children.isEmpty else { slot = .vertical(v); return }
            for i in v.children.indices {
                recomputeSizes(&v.children[i], width: width, height: height * v.children[i].fraction)
            }
            slot = .vertical(v)
        }
    }

}
