import Foundation
import CoreGraphics

// Structural mutations of the slot tree: removing leaves, updating leaves, flipping orientation, and wrapping slots.
struct TilingTreeMutationService {

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

    /// Replaces the identity (pid + windowHash) of a leaf without changing its layout.
    @discardableResult
    func replaceLeafIdentity(
        oldKey: WindowSlot, newPid: pid_t, newHash: UInt,
        in root: inout TilingRootSlot
    ) -> Bool {
        updateLeaf(oldKey, in: &root) { w in
            w = WindowSlot(pid: newPid, windowHash: newHash,
                           id: w.id, parentId: w.parentId,
                           order: w.order, size: w.size,
                           gaps: w.gaps, fraction: w.fraction,
                           preTileOrigin: w.preTileOrigin,
                           preTileSize: w.preTileSize,
                           isTabbed: true)
        }
    }

    /// Toggles the split orientation of the container that directly holds `key` (horizontal ↔ vertical).
    func flipParentOrientation(of key: WindowSlot, in root: inout TilingRootSlot) {
        if root.children.contains(where: {
            if case .window(let w) = $0 { return w == key }; return false
        }) {
            root.orientation = root.orientation.flipped
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
            fatalError("StackingSlot encountered in tiling tree mutation — stacking slots are not supported by TilingTreeMutationService")
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
            fatalError("StackingSlot encountered in tiling tree mutation — stacking slots are not supported by TilingTreeMutationService")
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
        case .split(var s):
            for i in s.children.indices {
                if updateLeaf(key, in: &s.children[i], update: update) {
                    slot = .split(s); return true
                }
            }
            return false
        case .stacking:
            fatalError("StackingSlot encountered in tiling tree mutation — stacking slots are not supported by TilingTreeMutationService")
        }
    }

    @discardableResult
    private func flipParentOrientation(of key: WindowSlot, in slot: inout Slot) -> Bool {
        switch slot {
        case .window: return false
        case .split(var s):
            if s.children.contains(where: {
                if case .window(let w) = $0 { return w == key }; return false
            }) {
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
            fatalError("StackingSlot encountered in tiling tree mutation — stacking slots are not supported by TilingTreeMutationService")
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
