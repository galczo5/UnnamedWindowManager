import AppKit

// Spatial neighbour-finding for directional window operations: leaf rect computation and nearest-neighbour search.
struct DirectionalNeighborService {

    struct LeafRect {
        let key: WindowSlot
        let rect: CGRect
    }

    static func findNeighbor(
        of currentKey: WindowSlot,
        direction: FocusDirection,
        in root: TilingRootSlot
    ) -> WindowSlot? {
        let rects = leafRects(in: root)
        guard let sourceRect = rects.first(where: { $0.key == currentKey })?.rect else { return nil }
        return nearest(from: sourceRect, direction: direction, candidates: rects, exclude: currentKey)
    }

    // MARK: - Private

    private enum Axis { case horizontal, vertical }

    static func leafRects(in root: TilingRootSlot) -> [LeafRect] {
        guard let screen = NSScreen.main else { return [] }
        let primaryHeight = NSScreen.screens[0].frame.height
        let visible = screen.visibleFrame
        let og = Config.outerGaps
        let origin = CGPoint(x: visible.minX + og.left!, y: primaryHeight - visible.maxY + og.top!)

        var results: [LeafRect] = []
        var cursor = origin
        for child in root.children {
            collectLeafRects(child, origin: cursor, into: &results)
            if root.orientation == .horizontal {
                cursor.x += child.width
            } else {
                cursor.y += child.height
            }
        }
        return results
    }

    private static func collectLeafRects(_ slot: Slot, origin: CGPoint, into results: inout [LeafRect]) {
        switch slot {
        case .window(let w):
            let g = w.gaps ? Config.innerGap : 0
            let rect = CGRect(
                x: (origin.x + g).rounded(),
                y: (origin.y + g).rounded(),
                width: (w.width - g * 2).rounded(),
                height: (w.height - g * 2).rounded()
            )
            results.append(LeafRect(key: w, rect: rect))
        case .split(let s):
            var cursor = origin
            for child in s.children {
                collectLeafRects(child, origin: cursor, into: &results)
                if s.orientation == .horizontal {
                    cursor.x += child.width
                } else {
                    cursor.y += child.height
                }
            }
        case .stacking:
            fatalError("StackingSlot encountered in tiling tree traversal — stacking slots are not supported by DirectionalNeighborService")
        }
    }

    private static func nearest(
        from source: CGRect,
        direction: FocusDirection,
        candidates: [LeafRect],
        exclude: WindowSlot
    ) -> WindowSlot? {
        let sc = CGPoint(x: source.midX, y: source.midY)

        let filtered = candidates.filter { lr in
            guard lr.key != exclude else { return false }
            let cc = CGPoint(x: lr.rect.midX, y: lr.rect.midY)
            switch direction {
            case .left:  return cc.x < sc.x
            case .right: return cc.x > sc.x
            case .up:    return cc.y < sc.y
            case .down:  return cc.y > sc.y
            }
        }

        func overlap(_ r: CGRect, _ s: CGRect, axis: Axis) -> CGFloat {
            switch axis {
            case .horizontal: return max(0, min(r.maxX, s.maxX) - max(r.minX, s.minX))
            case .vertical:   return max(0, min(r.maxY, s.maxY) - max(r.minY, s.minY))
            }
        }

        return filtered.min(by: { a, b in
            let ac = CGPoint(x: a.rect.midX, y: a.rect.midY)
            let bc = CGPoint(x: b.rect.midX, y: b.rect.midY)
            switch direction {
            case .left, .right:
                let oa = overlap(a.rect, source, axis: .vertical)
                let ob = overlap(b.rect, source, axis: .vertical)
                if oa != ob { return oa > ob }
                return abs(ac.x - sc.x) < abs(bc.x - sc.x)
            case .up, .down:
                let oa = overlap(a.rect, source, axis: .horizontal)
                let ob = overlap(b.rect, source, axis: .horizontal)
                if oa != ob { return oa > ob }
                return abs(ac.y - sc.y) < abs(bc.y - sc.y)
            }
        })?.key
    }
}
