import Foundation

// Insertion and swap operations on the slot tree: placing slots adjacent to targets and swapping window identities.
struct SlotTreeInsertService {

    /// Inserts `dragged` adjacent to the window identified by `targetKey`, honouring
    /// the directional `zone`. If the target's parent already has the matching orientation
    /// the dragged slot is inserted directly into that container; otherwise the target is
    /// wrapped in a new container of the needed orientation.
    /// The dragged window must have been removed from the tree before calling this.
    func insertAdjacentTo(
        _ dragged: Slot,
        adjacentTo targetKey: WindowSlot,
        zone: DropZone,
        in root: inout TilingRootSlot
    ) {
        Logger.shared.log("insertAdjacentTo: target=\(targetKey.windowHash) zone=\(zone)")
        let needed: Orientation = (zone == .left || zone == .right) ? .horizontal : .vertical
        let draggedFirst = (zone == .left || zone == .top)

        if let idx = root.children.firstIndex(where: {
            if case .window(let w) = $0 { return w == targetKey }
            return false
        }) {
            if root.orientation == needed {
                insertIntoChildren(&root.children, parentId: root.id,
                                   dragged: dragged, at: idx, draggedFirst: draggedFirst)
            } else {
                root.children[idx] = makeWrapper(target: root.children[idx],
                                                 dragged: dragged, orientation: needed,
                                                 draggedFirst: draggedFirst)
            }
            return
        }

        for i in root.children.indices {
            if insertAdjacentInSlot(&root.children[i], targetKey: targetKey,
                                    dragged: dragged, needed: needed,
                                    draggedFirst: draggedFirst) { return }
        }
    }

    /// Swaps the pid and windowHash of two window leaves in place, preserving their positions and fractions.
    func swap(_ keyA: WindowSlot, _ keyB: WindowSlot, in root: inout TilingRootSlot) {
        Logger.shared.log("swap: hashA=\(keyA.windowHash) hashB=\(keyB.windowHash)")
        let query = SlotTreeQueryService()
        guard query.findLeafSlot(keyA, in: root) != nil,
              query.findLeafSlot(keyB, in: root) != nil else { return }
        // Two-pass replacement collides when the windows are in different subtrees:
        // pass 1 places keyB at keyA's position, then pass 2 finds that new keyB first
        // and swaps it back, never reaching the original keyB. Fix: three passes with a
        // sentinel that is guaranteed not to match any real window (pid=0, hash=.max).
        let sentinel = WindowSlot(pid: 0, windowHash: .max,
                                  id: UUID(), parentId: UUID(),
                                  order: -1, width: 0, height: 0)
        for i in root.children.indices { replaceWindowInLeaf(&root.children[i], target: keyA, with: sentinel) }
        for i in root.children.indices { replaceWindowInLeaf(&root.children[i], target: keyB, with: keyA) }
        for i in root.children.indices { replaceWindowInLeaf(&root.children[i], target: sentinel, with: keyB) }
    }

    // MARK: - Private recursive helpers

    private func insertIntoChildren(
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

    private func makeWrapper(
        target: Slot,
        dragged: Slot,
        orientation: Orientation,
        draggedFirst: Bool
    ) -> Slot {
        let containerId = UUID()
        var d = dragged; d.parentId = containerId; d.fraction = 0.5
        var t = target;  t.parentId = containerId; t.fraction = 0.5
        let kids: [Slot] = draggedFirst ? [d, t] : [t, d]
        return orientation == .horizontal
            ? .horizontal(HorizontalSlot(id: containerId, parentId: target.parentId,
                                         width: 0, height: 0, children: kids,
                                         fraction: target.fraction))
            : .vertical(VerticalSlot(id: containerId, parentId: target.parentId,
                                     width: 0, height: 0, children: kids,
                                     fraction: target.fraction))
    }

    @discardableResult
    private func insertAdjacentInSlot(
        _ slot: inout Slot,
        targetKey: WindowSlot,
        dragged: Slot,
        needed: Orientation,
        draggedFirst: Bool
    ) -> Bool {
        switch slot {
        case .window:
            return false
        case .horizontal(var h):
            if let idx = h.children.firstIndex(where: {
                if case .window(let w) = $0 { return w == targetKey }; return false
            }) {
                if needed == .horizontal {
                    insertIntoChildren(&h.children, parentId: h.id,
                                       dragged: dragged, at: idx, draggedFirst: draggedFirst)
                } else {
                    h.children[idx] = makeWrapper(target: h.children[idx], dragged: dragged,
                                                  orientation: needed, draggedFirst: draggedFirst)
                }
                slot = .horizontal(h); return true
            }
            for i in h.children.indices {
                if insertAdjacentInSlot(&h.children[i], targetKey: targetKey,
                                        dragged: dragged, needed: needed,
                                        draggedFirst: draggedFirst) {
                    slot = .horizontal(h); return true
                }
            }
            return false
        case .vertical(var v):
            if let idx = v.children.firstIndex(where: {
                if case .window(let w) = $0 { return w == targetKey }; return false
            }) {
                if needed == .vertical {
                    insertIntoChildren(&v.children, parentId: v.id,
                                       dragged: dragged, at: idx, draggedFirst: draggedFirst)
                } else {
                    v.children[idx] = makeWrapper(target: v.children[idx], dragged: dragged,
                                                  orientation: needed, draggedFirst: draggedFirst)
                }
                slot = .vertical(v); return true
            }
            for i in v.children.indices {
                if insertAdjacentInSlot(&v.children[i], targetKey: targetKey,
                                        dragged: dragged, needed: needed,
                                        draggedFirst: draggedFirst) {
                    slot = .vertical(v); return true
                }
            }
            return false
        case .stacking:
            fatalError("StackingSlot encountered in tiling tree mutation — stacking slots are not supported by SlotTreeInsertService")
        }
    }

    @discardableResult
    private func replaceWindowInLeaf(
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
                width: w.width, height: w.height, gaps: w.gaps, fraction: w.fraction,
                preTileOrigin: replacement.preTileOrigin, preTileSize: replacement.preTileSize
            )
            slot = .window(swapped); return true
        case .horizontal(var h):
            for i in h.children.indices {
                if replaceWindowInLeaf(&h.children[i], target: target, with: replacement) {
                    slot = .horizontal(h); return true
                }
            }
            return false
        case .vertical(var v):
            for i in v.children.indices {
                if replaceWindowInLeaf(&v.children[i], target: target, with: replacement) {
                    slot = .vertical(v); return true
                }
            }
            return false
        case .stacking:
            fatalError("StackingSlot encountered in tiling tree mutation — stacking slots are not supported by SlotTreeInsertService")
        }
    }
}
