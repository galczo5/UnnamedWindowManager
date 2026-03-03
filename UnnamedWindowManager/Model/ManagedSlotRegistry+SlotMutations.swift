//
//  ManagedSlotRegistry+SlotMutations.swift
//  UnnamedWindowManager
//

import AppKit

extension ManagedSlotRegistry {

    /// Moves the slot containing `key` to just before `targetSlotIndex`.
    func moveSlot(containing key: ManagedWindow, before targetSlotIndex: Int) {
        queue.sync(flags: .barrier) {
            guard let srcIdx = self.indexOfSlot(containing: key),
                  srcIdx != targetSlotIndex,
                  targetSlotIndex >= 0, targetSlotIndex <= self.slots.count else { return }
            let slot = self.slots.remove(at: srcIdx)
            let insertIdx = srcIdx < targetSlotIndex ? targetSlotIndex - 1 : targetSlotIndex
            self.slots.insert(slot, at: insertIdx)
        }
    }

    /// Moves the slot containing `key` to just after `targetSlotIndex`.
    func moveSlot(containing key: ManagedWindow, after targetSlotIndex: Int) {
        queue.sync(flags: .barrier) {
            guard let srcIdx = self.indexOfSlot(containing: key),
                  srcIdx != targetSlotIndex,
                  targetSlotIndex >= 0, targetSlotIndex < self.slots.count else { return }
            let slot = self.slots.remove(at: srcIdx)
            let insertIdx = srcIdx < targetSlotIndex ? targetSlotIndex : targetSlotIndex + 1
            self.slots.insert(slot, at: insertIdx)
        }
    }

    /// Swaps two slots in the array.
    func swapSlots(_ i: Int, _ j: Int) {
        queue.sync(flags: .barrier) {
            guard i != j, i >= 0, j >= 0, i < self.slots.count, j < self.slots.count else { return }
            self.slots.swapAt(i, j)
        }
    }

    /// Swaps two windows within a slot (vertical swap).
    func swapWindowsInSlot(_ slotIndex: Int, _ i: Int, _ j: Int) {
        queue.sync(flags: .barrier) {
            guard slotIndex >= 0, slotIndex < self.slots.count,
                  i != j, i >= 0, j >= 0,
                  i < self.slots[slotIndex].windows.count,
                  j < self.slots[slotIndex].windows.count else { return }
            self.slots[slotIndex].windows.swapAt(i, j)
        }
    }

    /// Moves `draggedKey` from its current slot into `targetIndex` slot's window list.
    /// Removes the source slot if it becomes empty.
    /// Recomputes heights so all windows in the target slot share the available height equally.
    func splitVertical(_ draggedKey: ManagedWindow, intoSlot targetIndex: Int, screen: NSScreen) {
        let visible = screen.visibleFrame

        queue.sync(flags: .barrier) {
            guard targetIndex >= 0, targetIndex < self.slots.count else { return }

            // Find and remove dragged from its source slot.
            guard let srcIdx = self.indexOfSlot(containing: draggedKey) else { return }
            guard let srcWinIdx = self.slots[srcIdx].windows.firstIndex(of: draggedKey) else { return }
            let draggedWindow = self.slots[srcIdx].windows.remove(at: srcWinIdx)

            // Remove source slot if empty; adjust targetIndex if needed.
            var adjustedTarget = targetIndex
            if self.slots[srcIdx].windows.isEmpty {
                self.slots.remove(at: srcIdx)
                if srcIdx < adjustedTarget { adjustedTarget -= 1 }
            }

            guard adjustedTarget >= 0, adjustedTarget < self.slots.count else { return }

            // Add dragged window to target slot.
            var moved = draggedWindow
            let windowCount = CGFloat(self.slots[adjustedTarget].windows.count + 1)
            let perWindowH = (visible.height - Config.gap * (windowCount + 1)) / windowCount
            moved.height = perWindowH

            self.slots[adjustedTarget].windows.append(moved)

            // Equalize heights for all windows in the target slot.
            for wi in self.slots[adjustedTarget].windows.indices {
                self.slots[adjustedTarget].windows[wi].height = perWindowH
            }
        }
    }

    /// For each slot with exactly one window, resets its height to full screen.
    /// Removes empty slots.
    func normalizeSlots(screen: NSScreen) {
        let visible = screen.visibleFrame
        let fullH = visible.height - Config.gap * 2

        queue.sync(flags: .barrier) {
            // Remove empty slots.
            self.slots.removeAll { $0.windows.isEmpty }

            // Fix lone windows to full height.
            for si in self.slots.indices where self.slots[si].windows.count == 1 {
                self.slots[si].windows[0].height = fullH
            }
        }
    }

    // MARK: - Private (must be called inside barrier)

    private func indexOfSlot(containing key: ManagedWindow) -> Int? {
        slots.firstIndex { $0.windows.contains(key) }
    }
}
