//
//  ManagedSlotRegistry+SlotMutations.swift
//  UnnamedWindowManager
//

import Foundation

extension ManagedSlotRegistry {

    /// Swaps the two tracked windows in the tree.
    /// Each window moves to the other's leaf slot; slot sizes are unchanged.
    func swap(_ keyA: WindowSlot, _ keyB: WindowSlot) {
        queue.sync(flags: .barrier) {
            guard findLeafSlot(keyA, in: root) != nil,
                  findLeafSlot(keyB, in: root) != nil else { return }
            for i in root.children.indices {
                replaceWindowInLeaf(&root.children[i], target: keyA, with: keyB)
            }
            for i in root.children.indices {
                replaceWindowInLeaf(&root.children[i], target: keyB, with: keyA)
            }
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
