import Foundation
import CoreGraphics

// Recursive Slot-level helpers for TilingRootSlot tree operations.
// All methods are static and operate on inout Slot or plain Slot values.
// Not intended for use outside of TilingRootSlot.
struct TilingSlotRecursion {

    // MARK: - Query

    static func findLeaf(_ key: WindowSlot, in slot: Slot) -> Slot? {
        switch slot {
        case .window(let w):
            return w == key ? slot : nil
        case .split(let s):
            for child in s.children { if let f = findLeaf(key, in: child) { return f } }
            return nil
        case .stacking:
            fatalError("stacking slot in tiling tree")
        }
    }

    static func collectLeaves(in slot: Slot) -> [Slot] {
        switch slot {
        case .window:       return [slot]
        case .split(let s): return s.children.flatMap { collectLeaves(in: $0) }
        case .stacking:
            fatalError("stacking slot in tiling tree")
        }
    }

    static func maxLeafOrder(in slot: Slot) -> Int {
        switch slot {
        case .window(let w): return w.order
        case .split(let s):  return s.children.map { maxLeafOrder(in: $0) }.max() ?? 0
        case .stacking:
            fatalError("stacking slot in tiling tree")
        }
    }

    static func findParentOrientation(of key: WindowSlot, in slot: Slot) -> Orientation? {
        switch slot {
        case .window: return nil
        case .split(let s):
            if s.children.contains(where: { if case .window(let w) = $0 { return w == key }; return false }) {
                return s.orientation
            }
            for child in s.children { if let o = findParentOrientation(of: key, in: child) { return o } }
            return nil
        case .stacking:
            fatalError("stacking slot in tiling tree")
        }
    }

    // MARK: - Mutation

    static func removeFromTree(_ key: WindowSlot, slot: Slot) -> (slot: Slot?, found: Bool) {
        switch slot {
        case .window(let w):
            return w == key ? (nil, true) : (slot, false)
        case .split(let s):
            var found = false
            let newChildren: [Slot] = s.children.compactMap {
                let (child, wasFound) = removeFromTree(key, slot: $0)
                if wasFound { found = true }
                return child
            }
            guard found else { return (slot, false) }
            if newChildren.isEmpty { return (nil, true) }
            if newChildren.count == 1 {
                var child = newChildren[0]; child.parentId = s.parentId; child.fraction = s.fraction
                return (child, true)
            }
            var updated = s; updated.children = redistributed(newChildren)
            return (.split(updated), true)
        case .stacking:
            fatalError("stacking slot in tiling tree")
        }
    }

    @discardableResult
    static func extractAndWrap(
        _ slot: inout Slot,
        targetOrder: Int,
        newLeaf: Slot,
        orientation: Orientation
    ) -> Bool {
        if case .window(let w) = slot, w.order == targetOrder {
            let containerId = UUID()
            let containerParentId = slot.parentId
            let containerFraction = slot.fraction
            var existing = slot; existing.parentId = containerId; existing.fraction = 0.5
            var wrapped  = newLeaf; wrapped.parentId = containerId; wrapped.fraction = 0.5
            slot = .split(SplitSlot(id: containerId, parentId: containerParentId,
                                    size: .zero, orientation: orientation,
                                    children: [existing, wrapped],
                                    fraction: containerFraction))
            return true
        }
        switch slot {
        case .window: return false
        case .split(var s):
            for i in s.children.indices {
                if extractAndWrap(&s.children[i], targetOrder: targetOrder,
                                  newLeaf: newLeaf, orientation: orientation) {
                    slot = .split(s); return true
                }
            }
            return false
        case .stacking:
            fatalError("stacking slot in tiling tree")
        }
    }

    @discardableResult
    static func updateLeaf(
        _ key: WindowSlot,
        in slot: inout Slot,
        update: (inout WindowSlot) -> Void
    ) -> Bool {
        switch slot {
        case .window(var w):
            guard w == key else { return false }
            update(&w); slot = .window(w); return true
        case .split(var s):
            for i in s.children.indices {
                if updateLeaf(key, in: &s.children[i], update: update) {
                    slot = .split(s); return true
                }
            }
            return false
        case .stacking:
            fatalError("stacking slot in tiling tree")
        }
    }

    @discardableResult
    static func flipParentOrientation(of key: WindowSlot, in slot: inout Slot) -> Bool {
        switch slot {
        case .window: return false
        case .split(var s):
            if s.children.contains(where: { if case .window(let w) = $0 { return w == key }; return false }) {
                s.orientation = s.orientation.flipped
                slot = .split(s)
                return true
            }
            for i in s.children.indices {
                if flipParentOrientation(of: key, in: &s.children[i]) {
                    slot = .split(s); return true
                }
            }
            return false
        case .stacking:
            fatalError("stacking slot in tiling tree")
        }
    }

    static func redistributed(_ children: [Slot]) -> [Slot] {
        let freed = 1.0 - children.map(\.fraction).reduce(0, +)
        guard freed > 0, !children.isEmpty else { return children }
        let bonus = freed / CGFloat(children.count)
        return children.map { var s = $0; s.fraction += bonus; return s }
    }

    // MARK: - Insert

    @discardableResult
    static func insertAdjacentInSlot(
        _ slot: inout Slot,
        targetKey: WindowSlot,
        dragged: Slot,
        needed: Orientation,
        draggedFirst: Bool
    ) -> Bool {
        switch slot {
        case .window: return false
        case .split(var s):
            if let idx = s.children.firstIndex(where: {
                if case .window(let w) = $0 { return w == targetKey }; return false
            }) {
                if needed == s.orientation {
                    insertIntoChildren(&s.children, parentId: s.id,
                                       dragged: dragged, at: idx, draggedFirst: draggedFirst)
                } else {
                    s.children[idx] = makeWrapper(target: s.children[idx], dragged: dragged,
                                                  orientation: needed, draggedFirst: draggedFirst)
                }
                slot = .split(s); return true
            }
            for i in s.children.indices {
                if insertAdjacentInSlot(&s.children[i], targetKey: targetKey,
                                        dragged: dragged, needed: needed,
                                        draggedFirst: draggedFirst) {
                    slot = .split(s); return true
                }
            }
            return false
        case .stacking:
            fatalError("stacking slot in tiling tree")
        }
    }

    @discardableResult
    static func replaceWindowInLeaf(
        _ slot: inout Slot,
        target: WindowSlot,
        with replacement: WindowSlot
    ) -> Bool {
        switch slot {
        case .window(let w):
            guard w == target else { return false }
            let swapped = WindowSlot(
                pid: replacement.pid, windowHash: replacement.windowHash,
                id: w.id, parentId: w.parentId, order: w.order,
                size: w.size, gaps: w.gaps, fraction: w.fraction,
                preTileOrigin: replacement.preTileOrigin, preTileSize: replacement.preTileSize
            )
            slot = .window(swapped); return true
        case .split(var s):
            for i in s.children.indices {
                if replaceWindowInLeaf(&s.children[i], target: target, with: replacement) {
                    slot = .split(s); return true
                }
            }
            return false
        case .stacking:
            fatalError("stacking slot in tiling tree")
        }
    }

    static func insertIntoChildren(
        _ children: inout [Slot],
        parentId: UUID,
        dragged: Slot,
        at targetIdx: Int,
        draggedFirst: Bool
    ) {
        let half = children[targetIdx].fraction / 2
        var d = dragged; d.parentId = parentId; d.fraction = half
        var t = children[targetIdx]; t.fraction = half
        children[targetIdx] = t
        children.insert(d, at: draggedFirst ? targetIdx : targetIdx + 1)
    }

    static func makeWrapper(
        target: Slot,
        dragged: Slot,
        orientation: Orientation,
        draggedFirst: Bool
    ) -> Slot {
        let containerId = UUID()
        var d = dragged; d.parentId = containerId; d.fraction = 0.5
        var t = target;  t.parentId = containerId; t.fraction = 0.5
        let kids: [Slot] = draggedFirst ? [d, t] : [t, d]
        return .split(SplitSlot(id: containerId, parentId: target.parentId,
                                size: .zero, orientation: orientation,
                                children: kids, fraction: target.fraction))
    }

    // MARK: - Sizing

    static func recomputeSizes(_ slot: inout Slot, width: CGFloat, height: CGFloat) {
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
            for i in s.children.indices { s.children[i].size.height = height }
            slot = .stacking(s)
        }
    }

    // MARK: - Resize

    private static let minFraction: CGFloat = 0.05

    static func adjustFractions(
        _ children: inout [Slot],
        targetId: UUID,
        delta: CGFloat,
        horizontal: Bool,
        splitsHorizontal: Bool,
        sizeInAxis: CGFloat
    ) {
        _ = adjustFractionsImpl(&children, targetId: targetId, delta: delta,
                                horizontal: horizontal, splitsHorizontal: splitsHorizontal,
                                sizeInAxis: sizeInAxis)
    }

    private enum SearchResult { case notFound, adjusted, foundWrongAxis }

    @discardableResult
    private static func adjustFractionsImpl(
        _ children: inout [Slot],
        targetId: UUID,
        delta: CGFloat,
        horizontal: Bool,
        splitsHorizontal: Bool,
        sizeInAxis: CGFloat
    ) -> SearchResult {
        for i in children.indices {
            if children[i].id == targetId {
                guard splitsHorizontal == horizontal, sizeInAxis > 0 else { return .foundWrongAxis }
                applyFractionDelta(&children, targetIndex: i, fractionDelta: delta / sizeInAxis)
                return .adjusted
            }
            switch children[i] {
            case .window: continue
            case .split(var s):
                let isHoriz = s.orientation == .horizontal
                let result = adjustFractionsImpl(
                    &s.children, targetId: targetId, delta: delta, horizontal: horizontal,
                    splitsHorizontal: isHoriz, sizeInAxis: isHoriz ? s.size.width : s.size.height
                )
                switch result {
                case .notFound: continue
                case .adjusted:
                    children[i] = .split(s); return .adjusted
                case .foundWrongAxis:
                    guard splitsHorizontal == horizontal, sizeInAxis > 0 else { return .foundWrongAxis }
                    applyFractionDelta(&children, targetIndex: i, fractionDelta: delta / sizeInAxis)
                    return .adjusted
                }
            case .stacking:
                fatalError("stacking slot in tiling tree")
            }
        }
        return .notFound
    }

    private static func applyFractionDelta(
        _ children: inout [Slot],
        targetIndex: Int,
        fractionDelta: CGFloat
    ) {
        guard children.count >= 2 else { return }
        let siblingIndex = targetIndex + 1 < children.count ? targetIndex + 1 : targetIndex - 1
        let otherSum = children.indices
            .filter { $0 != targetIndex && $0 != siblingIndex }
            .map { children[$0].fraction }
            .reduce(0, +)
        let available = max(2 * minFraction, 1.0 - otherSum)
        var newTarget  = children[targetIndex].fraction  + fractionDelta
        var newSibling = children[siblingIndex].fraction - fractionDelta
        newTarget  = max(minFraction, min(available - minFraction, newTarget))
        newSibling = max(minFraction, available - newTarget)
        children[targetIndex].fraction  = newTarget
        children[siblingIndex].fraction = newSibling
    }
}
