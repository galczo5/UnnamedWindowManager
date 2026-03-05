//
//  SlotTreeService.swift
//  UnnamedWindowManager
//

import Foundation

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

    func swap(_ keyA: WindowSlot, _ keyB: WindowSlot, in root: inout RootSlot) {
        guard findLeafSlot(keyA, in: root) != nil,
              findLeafSlot(keyB, in: root) != nil else { return }
        for i in root.children.indices {
            replaceWindowInLeaf(&root.children[i], target: keyA, with: keyB)
        }
        for i in root.children.indices {
            replaceWindowInLeaf(&root.children[i], target: keyB, with: keyA)
        }
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
                width: w.width, height: w.height, gaps: w.gaps
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
