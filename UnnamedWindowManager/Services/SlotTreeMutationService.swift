import Foundation

// Structural mutations of the slot tree: removing leaves, updating leaves, flipping orientation, and wrapping slots.
struct SlotTreeMutationService {

    /// Removes the window leaf matching `key` from the tree, collapsing any single-child containers left behind.
    /// Returns `true` if the leaf was found and removed.
    @discardableResult
    func removeLeaf(_ key: WindowSlot, from root: inout TilingRootSlot) -> Bool {
        var found = false
        let newChildren: [Slot] = root.children.compactMap {
            let (newSlot, wasFound) = removeFromTree(key, slot: $0)
            if wasFound { found = true }
            return newSlot
        }
        if found { root.children = redistributed(newChildren) }
        return found
    }

    /// Finds the leaf with `targetOrder` and wraps it together with `newLeaf` in a new container of `orientation`.
    func extractAndWrap(
        in root: inout TilingRootSlot,
        targetOrder: Int,
        newLeaf: Slot,
        orientation: Orientation
    ) {
        for i in root.children.indices {
            if extractAndWrap(&root.children[i], targetOrder: targetOrder,
                              newLeaf: newLeaf, orientation: orientation) { return }
        }
    }

    /// Finds the leaf matching `key` and applies `update` to its `WindowSlot` in place.
    /// Returns `true` if the leaf was found and updated.
    @discardableResult
    func updateLeaf(
        _ key: WindowSlot,
        in root: inout TilingRootSlot,
        update: (inout WindowSlot) -> Void
    ) -> Bool {
        for i in root.children.indices {
            if updateLeaf(key, in: &root.children[i], update: update) { return true }
        }
        return false
    }

    /// Toggles the split orientation of the container that directly holds `key` (horizontal ↔ vertical).
    func flipParentOrientation(of key: WindowSlot, in root: inout TilingRootSlot) {
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

    // MARK: - Private recursive helpers

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
    private func redistributed(_ children: [Slot]) -> [Slot] {
        let freed = 1.0 - children.map(\.fraction).reduce(0, +)
        guard freed > 0, !children.isEmpty else { return children }
        let bonus = freed / CGFloat(children.count)
        return children.map { var s = $0; s.fraction += bonus; return s }
    }
}
