import Foundation
import CoreGraphics

// The root of the slot tree for a single screen.
// Owns all tree operations: query, mutation, insert, sizing, and resize.
struct TilingRootSlot {
    var id: UUID
    var size: CGSize
    var orientation: Orientation
    var children: [Slot]
    var gaps: Bool = true

    // MARK: - Query

    func isTracked(_ key: WindowSlot) -> Bool {
        findLeaf(key) != nil
    }

    func allLeaves() -> [Slot] {
        children.flatMap { TilingSlotRecursion.collectLeaves(in: $0) }
    }

    func findLeaf(_ key: WindowSlot) -> Slot? {
        children.compactMap { TilingSlotRecursion.findLeaf(key, in: $0) }.first
    }

    func maxLeafOrder() -> Int {
        children.map { TilingSlotRecursion.maxLeafOrder(in: $0) }.max() ?? 0
    }

    func parentOrientation(of key: WindowSlot) -> Orientation? {
        if children.contains(where: { if case .window(let w) = $0 { return w == key }; return false }) {
            return orientation
        }
        for child in children {
            if let o = TilingSlotRecursion.findParentOrientation(of: key, in: child) { return o }
        }
        return nil
    }

    // MARK: - Mutation

    @discardableResult
    mutating func removeLeaf(_ key: WindowSlot) -> Bool {
        var found = false
        let newChildren: [Slot] = children.compactMap {
            let (newSlot, wasFound) = TilingSlotRecursion.removeFromTree(key, slot: $0)
            if wasFound { found = true }
            return newSlot
        }
        if found { children = TilingSlotRecursion.redistributed(newChildren) }
        return found
    }

    mutating func extractAndWrap(targetOrder: Int, newLeaf: Slot, orientation: Orientation) {
        for i in children.indices {
            if TilingSlotRecursion.extractAndWrap(&children[i], targetOrder: targetOrder,
                                                   newLeaf: newLeaf, orientation: orientation) { return }
        }
    }

    @discardableResult
    mutating func updateLeaf(_ key: WindowSlot, update: (inout WindowSlot) -> Void) -> Bool {
        for i in children.indices {
            if TilingSlotRecursion.updateLeaf(key, in: &children[i], update: update) { return true }
        }
        return false
    }

    @discardableResult
    mutating func replaceLeafIdentity(oldKey: WindowSlot, newPid: pid_t, newHash: UInt) -> Bool {
        updateLeaf(oldKey) { w in
            var s = WindowSlot(pid: newPid, windowHash: newHash,
                               id: w.id, parentId: w.parentId,
                               order: w.order, size: w.size,
                               gaps: w.gaps, fraction: w.fraction,
                               preTileOrigin: w.preTileOrigin, preTileSize: w.preTileSize,
                               isTabbed: true)
            s.tabHashes = TabDetector.tabSiblingHashes(of: newHash, pid: newPid)
            w = s
        }
    }

    mutating func flipParentOrientation(of key: WindowSlot) {
        if children.contains(where: { if case .window(let w) = $0 { return w == key }; return false }) {
            orientation = orientation.flipped
            return
        }
        for i in children.indices {
            if TilingSlotRecursion.flipParentOrientation(of: key, in: &children[i]) { return }
        }
    }

    // MARK: - Insert

    mutating func insertAdjacent(_ dragged: Slot, adjacentTo targetKey: WindowSlot, zone: DropZone) {
        let needed: Orientation = (zone == .left || zone == .right) ? .horizontal : .vertical
        let draggedFirst = (zone == .left || zone == .top)

        if let idx = children.firstIndex(where: {
            if case .window(let w) = $0 { return w == targetKey }; return false
        }) {
            if orientation == needed {
                TilingSlotRecursion.insertIntoChildren(&children, parentId: id,
                                                        dragged: dragged, at: idx,
                                                        draggedFirst: draggedFirst)
            } else {
                children[idx] = TilingSlotRecursion.makeWrapper(
                    target: children[idx], dragged: dragged,
                    orientation: needed, draggedFirst: draggedFirst)
            }
            return
        }
        for i in children.indices {
            if TilingSlotRecursion.insertAdjacentInSlot(&children[i], targetKey: targetKey,
                                                         dragged: dragged, needed: needed,
                                                         draggedFirst: draggedFirst) { return }
        }
    }

    mutating func swap(_ keyA: WindowSlot, _ keyB: WindowSlot) {
        guard findLeaf(keyA) != nil, findLeaf(keyB) != nil else { return }
        let sentinel = WindowSlot(pid: 0, windowHash: .max,
                                  id: UUID(), parentId: UUID(), order: -1, size: .zero)
        for i in children.indices { TilingSlotRecursion.replaceWindowInLeaf(&children[i], target: keyA, with: sentinel) }
        for i in children.indices { TilingSlotRecursion.replaceWindowInLeaf(&children[i], target: keyB, with: keyA) }
        for i in children.indices { TilingSlotRecursion.replaceWindowInLeaf(&children[i], target: sentinel, with: keyB) }
    }

    // MARK: - Sizing

    mutating func recomputeSizes(width: CGFloat, height: CGFloat) {
        size = CGSize(width: width, height: height)
        guard !children.isEmpty else { return }
        for i in children.indices {
            let cw = orientation == .horizontal ? (width * children[i].fraction).rounded() : width
            let ch = orientation == .horizontal ? height : (height * children[i].fraction).rounded()
            TilingSlotRecursion.recomputeSizes(&children[i], width: cw, height: ch)
        }
    }

    // MARK: - Resize

    mutating func applyResize(key: WindowSlot, actualSize: CGSize) {
        guard let leaf = findLeaf(key), case .window(let w) = leaf else { return }
        let gap = w.gaps ? Config.innerGap * 2 : 0
        let dw = (actualSize.width + gap) - w.size.width
        let dh = (actualSize.height + gap) - w.size.height
        let resizeH = abs(dw) >= abs(dh)
        let delta = resizeH ? dw : dh
        guard abs(delta) > 1.0 else { return }
        let splitsH = orientation == .horizontal
        let sizeInAxis = splitsH ? size.width : size.height
        TilingSlotRecursion.adjustFractions(&children, targetId: w.id, delta: delta,
                                             horizontal: resizeH, splitsHorizontal: splitsH,
                                             sizeInAxis: sizeInAxis)
    }
}
