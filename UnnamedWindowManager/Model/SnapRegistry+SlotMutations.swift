//
//  SnapRegistry+SlotMutations.swift
//  UnnamedWindowManager
//

import AppKit

extension SnapRegistry {

    /// Moves `key` to the slot immediately before `targetKey`, shifting others to fill.
    func moveSlot(_ key: SnapKey, before targetKey: SnapKey) {
        queue.sync(flags: .barrier) {
            var ordered = self.row0Ordered()
            guard ordered.contains(key), ordered.contains(targetKey), key != targetKey else { return }
            ordered.removeAll { $0 == key }
            let insertIdx = ordered.firstIndex(of: targetKey)!
            ordered.insert(key, at: insertIdx)
            self.applySlotOrder(ordered)
        }
    }

    /// Moves `key` to the slot immediately after `targetKey`, shifting others to fill.
    func moveSlot(_ key: SnapKey, after targetKey: SnapKey) {
        queue.sync(flags: .barrier) {
            var ordered = self.row0Ordered()
            guard ordered.contains(key), ordered.contains(targetKey), key != targetKey else { return }
            ordered.removeAll { $0 == key }
            let insertIdx = ordered.firstIndex(of: targetKey)!
            ordered.insert(key, at: insertIdx + 1)
            self.applySlotOrder(ordered)
        }
    }

    /// Stacks `draggedKey` below `targetKey` in the same horizontal column.
    /// Both windows are resized to half the visible screen height (top gap + middle gap + bottom gap).
    func splitVertical(_ draggedKey: SnapKey, below targetKey: SnapKey, screen: NSScreen) {
        let visible = screen.visibleFrame
        let halfH   = (visible.height - Config.gap * 3) / 2

        queue.sync(flags: .barrier) {
            guard let targetEntry = self.store[targetKey] else { return }
            self.store[targetKey]?.height = halfH
            self.store[draggedKey]?.slot   = targetEntry.slot
            self.store[draggedKey]?.row    = 1
            self.store[draggedKey]?.height = halfH
            self.store[draggedKey]?.width  = targetEntry.width
        }
    }

    /// For every slot that now has exactly one window, resets its height to full screen
    /// and clears any leftover row-1 flag. Also compacts slots to remove any gaps.
    /// Call this after any slot mutation.
    func normalizeHeights(screen: NSScreen) {
        let visible = screen.visibleFrame
        let fullH   = visible.height - Config.gap * 2

        queue.sync(flags: .barrier) {
            let slotGroups = Dictionary(grouping: self.store.keys) { self.store[$0]!.slot }
            for (_, keys) in slotGroups where keys.count == 1 {
                guard let key = keys.first else { continue }
                self.store[key]?.height = fullH
                self.store[key]?.row    = 0
            }
            // Compact row-0 slots to 0, 1, 2, … and update row-1 partners to match.
            self.applySlotOrder(self.row0Ordered())
        }
    }

    func swapSlots(_ key1: SnapKey, _ key2: SnapKey) {
        queue.sync(flags: .barrier) {
            guard var e1 = self.store[key1], var e2 = self.store[key2] else { return }
            if e1.slot == e2.slot {
                // Same column (vertical split): swap rows so top and bottom exchange positions.
                swap(&e1.row, &e2.row)
            } else {
                swap(&e1.slot, &e2.slot)
            }
            swap(&e1.height, &e2.height)
            self.store[key1] = e1
            self.store[key2] = e2
        }
    }

    // MARK: - Private helpers (must be called from within a barrier block)

    /// Returns row-0 keys sorted ascending by their current slot value.
    private func row0Ordered() -> [SnapKey] {
        store.filter { $0.value.row == 0 }
             .map { (key: $0.key, slot: $0.value.slot) }
             .sorted { $0.slot < $1.slot }
             .map { $0.key }
    }

    /// Assigns consecutive slots 0, 1, 2… to `ordered` (row-0 keys) and remaps
    /// every row-1 partner to follow its row-0 window's new slot.
    private func applySlotOrder(_ ordered: [SnapKey]) {
        // Capture old slot for each row-0 key before any mutation.
        var slotRemap: [Int: Int] = [:]
        for (newSlot, k) in ordered.enumerated() {
            if let oldSlot = store[k]?.slot {
                slotRemap[oldSlot] = newSlot
            }
        }
        // Apply new slots to row-0 windows.
        for (newSlot, k) in ordered.enumerated() {
            store[k]?.slot = newSlot
        }
        // Remap row-1 partners using the old→new slot table.
        for k in store.keys where store[k]?.row == 1 {
            if let old = store[k]?.slot, let new = slotRemap[old] {
                store[k]?.slot = new
            }
        }
    }
}
