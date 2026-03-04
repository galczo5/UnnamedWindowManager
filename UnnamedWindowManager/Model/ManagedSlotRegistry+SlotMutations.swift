//
//  ManagedSlotRegistry+SlotMutations.swift
//  UnnamedWindowManager
//

import Foundation

extension ManagedSlotRegistry {

    /// Swaps the two tracked windows in the tree.
    /// Each window moves to the other's leaf slot; slot sizes are unchanged.
    func swap(_ keyA: ManagedWindow, _ keyB: ManagedWindow) {
        queue.sync(flags: .barrier) {
            guard findLeafSlot(keyA, in: root) != nil,
                  findLeafSlot(keyB, in: root) != nil else { return }
            replaceWindowInLeaf(&root, target: keyA, with: keyB)
            replaceWindowInLeaf(&root, target: keyB, with: keyA)
        }
    }

    @discardableResult
    private func replaceWindowInLeaf(
        _ slot: inout ManagedSlot,
        target: ManagedWindow,
        with replacement: ManagedWindow
    ) -> Bool {
        if case .window(let w) = slot.content, w == target {
            slot.content = .window(replacement)
            return true
        }
        if case .slots(var children) = slot.content {
            for i in children.indices {
                if replaceWindowInLeaf(&children[i], target: target, with: replacement) {
                    slot.content = .slots(children)
                    return true
                }
            }
        }
        return false
    }
}
