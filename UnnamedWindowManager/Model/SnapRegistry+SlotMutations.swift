//
//  SnapRegistry+SlotMutations.swift
//  UnnamedWindowManager
//

import Foundation

extension SnapRegistry {

    /// Moves `key` to the slot immediately before `targetKey`, shifting others to fill.
    func moveSlot(_ key: SnapKey, before targetKey: SnapKey) {
        queue.sync(flags: .barrier) {
            var ordered = self.store
                .map { (key: $0.key, slot: $0.value.slot) }
                .sorted { $0.slot < $1.slot }
                .map(\.key)

            guard ordered.contains(key), ordered.contains(targetKey), key != targetKey else { return }

            ordered.removeAll { $0 == key }
            let insertIdx = ordered.firstIndex(of: targetKey)!
            ordered.insert(key, at: insertIdx)

            for (i, k) in ordered.enumerated() {
                self.store[k]?.slot = i
            }
        }
    }

    /// Moves `key` to the slot immediately after `targetKey`, shifting others to fill.
    func moveSlot(_ key: SnapKey, after targetKey: SnapKey) {
        queue.sync(flags: .barrier) {
            var ordered = self.store
                .map { (key: $0.key, slot: $0.value.slot) }
                .sorted { $0.slot < $1.slot }
                .map(\.key)

            guard ordered.contains(key), ordered.contains(targetKey), key != targetKey else { return }

            ordered.removeAll { $0 == key }
            let insertIdx = ordered.firstIndex(of: targetKey)!
            ordered.insert(key, at: insertIdx + 1)

            for (i, k) in ordered.enumerated() {
                self.store[k]?.slot = i
            }
        }
    }

    func swapSlots(_ key1: SnapKey, _ key2: SnapKey) {
        queue.sync(flags: .barrier) {
            guard var e1 = self.store[key1], var e2 = self.store[key2] else { return }
            swap(&e1.slot, &e2.slot)
            self.store[key1] = e1
            self.store[key2] = e2
        }
    }
}
