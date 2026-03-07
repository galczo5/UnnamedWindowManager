import Foundation

// Pure tree manipulation: inserting, removing, querying, and restructuring slots in the layout tree.
struct SlotTreeService {

    // MARK: - Queries

    func isTracked(_ key: WindowSlot, in root: RootSlot) -> Bool {
        findLeafSlot(key, in: root) != nil
    }

    func allLeaves(in root: RootSlot) -> [Slot] {
        collectLeaves(in: root)
    }

    func findLeafSlot(_ key: WindowSlot, in root: RootSlot) -> Slot? {
        root.children.compactMap { findLeafSlot(key, in: $0) }.first
    }

    func maxLeafOrder(in root: RootSlot) -> Int {
        root.children.map { maxLeafOrder(in: $0) }.max() ?? 0
    }

    func findParentOrientation(of key: WindowSlot, in root: RootSlot) -> Orientation? {
        if root.children.contains(where: {
            if case .window(let w) = $0 { return w == key }; return false
        }) { return root.orientation }
        for child in root.children {
            if let o = findParentOrientation(of: key, in: child) { return o }
        }
        return nil
    }

    func flipParentOrientation(of key: WindowSlot, in root: inout RootSlot) {
        if root.children.contains(where: {
            if case .window(let w) = $0 { return w == key }; return false
        }) {
            root.orientation = root.orientation == .horizontal ? .vertical : .horizontal
            return
        }
        for i in root.children.indices {
            if flipParentOrientation(of: key, in: &root.children[i]) { return }
        }
    }

    // MARK: - Structural mutations

    @discardableResult
    func removeLeaf(_ key: WindowSlot, from root: inout RootSlot) -> Bool {
        var found = false
        let newChildren: [Slot] = root.children.compactMap {
            let (newSlot, wasFound) = removeFromTree(key, slot: $0)
            if wasFound { found = true }
            return newSlot
        }
        if found { root.children = newChildren }
        return found
    }

    func extractAndWrap(
        in root: inout RootSlot,
        targetOrder: Int,
        newLeaf: Slot,
        orientation: Orientation
    ) {
        for i in root.children.indices {
            if extractAndWrap(&root.children[i], targetOrder: targetOrder,
                              newLeaf: newLeaf, orientation: orientation) { return }
        }
    }

    @discardableResult
    func updateLeaf(
        _ key: WindowSlot,
        in root: inout RootSlot,
        update: (inout WindowSlot) -> Void
    ) -> Bool {
        for i in root.children.indices {
            if updateLeaf(key, in: &root.children[i], update: update) { return true }
        }
        return false
    }

    /// Inserts `dragged` adjacent to the window identified by `targetKey`, honouring
    /// the directional `zone`. If the target's parent already has the matching orientation
    /// the dragged slot is inserted directly into that container; otherwise the target is
    /// wrapped in a new container of the needed orientation.
    /// The dragged window must have been removed from the tree before calling this.
    func insertAdjacentTo(
        _ dragged: Slot,
        adjacentTo targetKey: WindowSlot,
        zone: DropZone,
        in root: inout RootSlot
    ) {
        let needed: Orientation = (zone == .left || zone == .right) ? .horizontal : .vertical
        let draggedFirst = (zone == .left || zone == .top)

        // Check root-level children first.
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

    func swap(_ keyA: WindowSlot, _ keyB: WindowSlot, in root: inout RootSlot) {
        guard findLeafSlot(keyA, in: root) != nil,
              findLeafSlot(keyB, in: root) != nil else { return }
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

    private func findLeafSlot(_ key: WindowSlot, in slot: Slot) -> Slot? {
        switch slot {
        case .window(let w):
            return w == key ? slot : nil
        case .horizontal(let h):
            for child in h.children { if let f = findLeafSlot(key, in: child) { return f } }
            return nil
        case .vertical(let v):
            for child in v.children { if let f = findLeafSlot(key, in: child) { return f } }
            return nil
        }
    }

    private func collectLeaves(in root: RootSlot) -> [Slot] {
        root.children.flatMap { collectLeaves(in: $0) }
    }

    private func collectLeaves(in slot: Slot) -> [Slot] {
        switch slot {
        case .window:            return [slot]
        case .horizontal(let h): return h.children.flatMap { collectLeaves(in: $0) }
        case .vertical(let v):   return v.children.flatMap { collectLeaves(in: $0) }
        }
    }

    private func removeFromTree(_ key: WindowSlot, slot: Slot) -> (slot: Slot?, found: Bool) {
        switch slot {
        case .window(let w):
            return w == key ? (nil, true) : (slot, false)
        case .horizontal(let h):
            var found = false
            let newChildren: [Slot] = h.children.compactMap {
                let (s, wasFound) = removeFromTree(key, slot: $0)
                if wasFound { found = true }
                return s
            }
            guard found else { return (slot, false) }
            if newChildren.isEmpty { return (nil, true) }
            if newChildren.count == 1 {
                var child = newChildren[0]; child.parentId = h.parentId; child.fraction = h.fraction
                return (child, true)
            }
            var updated = h; updated.children = redistributed(newChildren)
            return (.horizontal(updated), true)
        case .vertical(let v):
            var found = false
            let newChildren: [Slot] = v.children.compactMap {
                let (s, wasFound) = removeFromTree(key, slot: $0)
                if wasFound { found = true }
                return s
            }
            guard found else { return (slot, false) }
            if newChildren.isEmpty { return (nil, true) }
            if newChildren.count == 1 {
                var child = newChildren[0]; child.parentId = v.parentId; child.fraction = v.fraction
                return (child, true)
            }
            var updated = v; updated.children = redistributed(newChildren)
            return (.vertical(updated), true)
        }
    }

    @discardableResult
    private func extractAndWrap(
        _ slot: inout Slot,
        targetOrder: Int,
        newLeaf: Slot,
        orientation: Orientation
    ) -> Bool {
        if case .window(let w) = slot, w.order == targetOrder {
            let containerId = UUID()
            let containerParentId = slot.parentId
            let containerFraction = slot.fraction
            var existing = slot;  existing.parentId = containerId; existing.fraction = 0.5
            var wrapped  = newLeaf; wrapped.parentId = containerId; wrapped.fraction = 0.5
            slot = orientation == .horizontal
                ? .horizontal(HorizontalSlot(id: containerId, parentId: containerParentId,
                                             width: 0, height: 0, children: [existing, wrapped],
                                             fraction: containerFraction))
                : .vertical(VerticalSlot(id: containerId, parentId: containerParentId,
                                         width: 0, height: 0, children: [existing, wrapped],
                                         fraction: containerFraction))
            return true
        }
        switch slot {
        case .window: return false
        case .horizontal(var h):
            for i in h.children.indices {
                if extractAndWrap(&h.children[i], targetOrder: targetOrder,
                                  newLeaf: newLeaf, orientation: orientation) {
                    slot = .horizontal(h); return true
                }
            }
            return false
        case .vertical(var v):
            for i in v.children.indices {
                if extractAndWrap(&v.children[i], targetOrder: targetOrder,
                                  newLeaf: newLeaf, orientation: orientation) {
                    slot = .vertical(v); return true
                }
            }
            return false
        }
    }

    private func maxLeafOrder(in slot: Slot) -> Int {
        switch slot {
        case .window(let w):     return w.order
        case .horizontal(let h): return h.children.map { maxLeafOrder(in: $0) }.max() ?? 0
        case .vertical(let v):   return v.children.map { maxLeafOrder(in: $0) }.max() ?? 0
        }
    }

    @discardableResult
    private func updateLeaf(
        _ key: WindowSlot,
        in slot: inout Slot,
        update: (inout WindowSlot) -> Void
    ) -> Bool {
        switch slot {
        case .window(var w):
            guard w == key else { return false }
            update(&w); slot = .window(w); return true
        case .horizontal(var h):
            for i in h.children.indices {
                if updateLeaf(key, in: &h.children[i], update: update) {
                    slot = .horizontal(h); return true
                }
            }
            return false
        case .vertical(var v):
            for i in v.children.indices {
                if updateLeaf(key, in: &v.children[i], update: update) {
                    slot = .vertical(v); return true
                }
            }
            return false
        }
    }

    /// Inserts `dragged` into `children` at the correct position relative to `targetIdx`,
    /// splitting the target's fraction equally with the new sibling.
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

    /// Wraps `target` and `dragged` in a new container of `orientation`.
    /// The container inherits the target's fraction and parentId.
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

    /// Recursively searches `slot` for `targetKey` and inserts `dragged` adjacent to it.
    /// Returns `true` when the insertion was performed.
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
        }
    }

    private func findParentOrientation(of key: WindowSlot, in slot: Slot) -> Orientation? {
        switch slot {
        case .window: return nil
        case .horizontal(let h):
            if h.children.contains(where: {
                if case .window(let w) = $0 { return w == key }; return false
            }) { return .horizontal }
            for child in h.children { if let o = findParentOrientation(of: key, in: child) { return o } }
            return nil
        case .vertical(let v):
            if v.children.contains(where: {
                if case .window(let w) = $0 { return w == key }; return false
            }) { return .vertical }
            for child in v.children { if let o = findParentOrientation(of: key, in: child) { return o } }
            return nil
        }
    }

    @discardableResult
    private func flipParentOrientation(of key: WindowSlot, in slot: inout Slot) -> Bool {
        switch slot {
        case .window: return false
        case .horizontal(var h):
            if h.children.contains(where: {
                if case .window(let w) = $0 { return w == key }; return false
            }) {
                slot = .vertical(VerticalSlot(id: h.id, parentId: h.parentId,
                                              width: h.width, height: h.height,
                                              children: h.children, gaps: h.gaps,
                                              fraction: h.fraction))
                return true
            }
            for i in h.children.indices {
                if flipParentOrientation(of: key, in: &h.children[i]) {
                    slot = .horizontal(h); return true
                }
            }
            return false
        case .vertical(var v):
            if v.children.contains(where: {
                if case .window(let w) = $0 { return w == key }; return false
            }) {
                slot = .horizontal(HorizontalSlot(id: v.id, parentId: v.parentId,
                                                  width: v.width, height: v.height,
                                                  children: v.children, gaps: v.gaps,
                                                  fraction: v.fraction))
                return true
            }
            for i in v.children.indices {
                if flipParentOrientation(of: key, in: &v.children[i]) {
                    slot = .vertical(v); return true
                }
            }
            return false
        }
    }

    /// Distributes the fraction freed by a removed sibling equally among `children`.
    /// Assumes the removed child's fraction was already excluded (compactMap filtered it out),
    /// so the existing fractions sum to less than 1.0 and the deficit is spread evenly.
    private func redistributed(_ children: [Slot]) -> [Slot] {
        let freed = 1.0 - children.map(\.fraction).reduce(0, +)
        guard freed > 0, !children.isEmpty else { return children }
        let bonus = freed / CGFloat(children.count)
        return children.map { var s = $0; s.fraction += bonus; return s }
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
                width: w.width, height: w.height, gaps: w.gaps, fraction: w.fraction
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
        }
    }
}
