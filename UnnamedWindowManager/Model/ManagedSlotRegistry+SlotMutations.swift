//
//  ManagedSlotRegistry+SlotMutations.swift
//  UnnamedWindowManager
//

import AppKit

extension ManagedSlotRegistry {

    /// Extracts `draggedKey` from its slot and creates a new slot before `targetSlotIndex`.
    /// The new slot uses the source slot's width; the window gets full screen height.
    /// Equalizes heights of any remaining windows in the source slot.
    func insertSlotBefore(_ draggedKey: ManagedWindow, targetSlot targetSlotIndex: Int, screen: NSScreen) {
        let visible = screen.visibleFrame
        let fullH = visible.height - Config.gap * 2

        queue.sync(flags: .barrier) {
            guard targetSlotIndex >= 0, targetSlotIndex < self.slots.count else { return }
            guard let srcIdx = self.indexOfSlot(containing: draggedKey) else { return }
            guard let srcWinIdx = self.slots[srcIdx].windows.firstIndex(of: draggedKey) else { return }

            let sourceWidth = self.slots[srcIdx].width
            var draggedWindow = self.slots[srcIdx].windows.remove(at: srcWinIdx)
            draggedWindow.height = fullH

            var adjustedTarget = targetSlotIndex
            if self.slots[srcIdx].windows.isEmpty {
                self.slots.remove(at: srcIdx)
                if srcIdx < adjustedTarget { adjustedTarget -= 1 }
            } else {
                self.equalizeHeights(inSlot: srcIdx, visibleHeight: visible.height)
            }

            let newSlot = ManagedSlot(width: sourceWidth, windows: [draggedWindow])
            self.slots.insert(newSlot, at: adjustedTarget)
            self.renumberOrders()
        }
    }

    /// Extracts `draggedKey` from its slot and creates a new slot after `targetSlotIndex`.
    /// The new slot uses the source slot's width; the window gets full screen height.
    /// Equalizes heights of any remaining windows in the source slot.
    func insertSlotAfter(_ draggedKey: ManagedWindow, targetSlot targetSlotIndex: Int, screen: NSScreen) {
        let visible = screen.visibleFrame
        let fullH = visible.height - Config.gap * 2

        queue.sync(flags: .barrier) {
            guard targetSlotIndex >= 0, targetSlotIndex < self.slots.count else { return }
            guard let srcIdx = self.indexOfSlot(containing: draggedKey) else { return }
            guard let srcWinIdx = self.slots[srcIdx].windows.firstIndex(of: draggedKey) else { return }

            let sourceWidth = self.slots[srcIdx].width
            var draggedWindow = self.slots[srcIdx].windows.remove(at: srcWinIdx)
            draggedWindow.height = fullH

            var adjustedTarget = targetSlotIndex
            if self.slots[srcIdx].windows.isEmpty {
                self.slots.remove(at: srcIdx)
                if srcIdx < adjustedTarget { adjustedTarget -= 1 }
            } else {
                self.equalizeHeights(inSlot: srcIdx, visibleHeight: visible.height)
            }

            let newSlot = ManagedSlot(width: sourceWidth, windows: [draggedWindow])
            let insertIdx = adjustedTarget + 1
            self.slots.insert(newSlot, at: min(insertIdx, self.slots.count))
            self.renumberOrders()
        }
    }

    /// Moves `draggedKey` into `targetIndex` slot as the first window.
    /// Equalizes heights of all windows in both source and target slots.
    func insertWindowTop(_ draggedKey: ManagedWindow, intoSlot targetIndex: Int, screen: NSScreen) {
        let visible = screen.visibleFrame

        queue.sync(flags: .barrier) {
            guard targetIndex >= 0, targetIndex < self.slots.count else { return }
            guard let srcIdx = self.indexOfSlot(containing: draggedKey) else { return }
            guard let srcWinIdx = self.slots[srcIdx].windows.firstIndex(of: draggedKey) else { return }

            let draggedWindow = self.slots[srcIdx].windows.remove(at: srcWinIdx)

            var adjustedTarget = targetIndex
            if self.slots[srcIdx].windows.isEmpty {
                self.slots.remove(at: srcIdx)
                if srcIdx < adjustedTarget { adjustedTarget -= 1 }
            } else {
                self.equalizeHeights(inSlot: srcIdx, visibleHeight: visible.height)
            }

            guard adjustedTarget >= 0, adjustedTarget < self.slots.count else { return }

            var moved = draggedWindow
            let windowCount = CGFloat(self.slots[adjustedTarget].windows.count + 1)
            let perWindowH = (visible.height - Config.gap * (windowCount + 1)) / windowCount
            moved.height = perWindowH

            self.slots[adjustedTarget].windows.insert(moved, at: 0)

            for wi in self.slots[adjustedTarget].windows.indices {
                self.slots[adjustedTarget].windows[wi].height = perWindowH
            }
        }
    }

    /// Moves `draggedKey` into `targetIndex` slot as the last window.
    /// Equalizes heights of all windows in both source and target slots.
    func insertWindowBottom(_ draggedKey: ManagedWindow, intoSlot targetIndex: Int, screen: NSScreen) {
        let visible = screen.visibleFrame

        queue.sync(flags: .barrier) {
            guard targetIndex >= 0, targetIndex < self.slots.count else { return }
            guard let srcIdx = self.indexOfSlot(containing: draggedKey) else { return }
            guard let srcWinIdx = self.slots[srcIdx].windows.firstIndex(of: draggedKey) else { return }

            let draggedWindow = self.slots[srcIdx].windows.remove(at: srcWinIdx)

            var adjustedTarget = targetIndex
            if self.slots[srcIdx].windows.isEmpty {
                self.slots.remove(at: srcIdx)
                if srcIdx < adjustedTarget { adjustedTarget -= 1 }
            } else {
                self.equalizeHeights(inSlot: srcIdx, visibleHeight: visible.height)
            }

            guard adjustedTarget >= 0, adjustedTarget < self.slots.count else { return }

            var moved = draggedWindow
            let windowCount = CGFloat(self.slots[adjustedTarget].windows.count + 1)
            let perWindowH = (visible.height - Config.gap * (windowCount + 1)) / windowCount
            moved.height = perWindowH

            self.slots[adjustedTarget].windows.append(moved)

            for wi in self.slots[adjustedTarget].windows.indices {
                self.slots[adjustedTarget].windows[wi].height = perWindowH
            }
        }
    }

    /// Swaps two individual windows. Each window moves to the other's (slot, index) position.
    /// Heights travel with the windows (i.e. heights are swapped).
    func swapWindows(
        _ a: (slotIndex: Int, windowIndex: Int),
        with b: (slotIndex: Int, windowIndex: Int)
    ) {
        queue.sync(flags: .barrier) {
            guard a.slotIndex >= 0, a.slotIndex < self.slots.count,
                  b.slotIndex >= 0, b.slotIndex < self.slots.count,
                  a.windowIndex >= 0, a.windowIndex < self.slots[a.slotIndex].windows.count,
                  b.windowIndex >= 0, b.windowIndex < self.slots[b.slotIndex].windows.count
            else { return }

            if a.slotIndex == b.slotIndex {
                self.slots[a.slotIndex].windows.swapAt(a.windowIndex, b.windowIndex)
                return
            }

            let winA = self.slots[a.slotIndex].windows[a.windowIndex]
            let winB = self.slots[b.slotIndex].windows[b.windowIndex]
            self.slots[a.slotIndex].windows[a.windowIndex] = winB
            self.slots[b.slotIndex].windows[b.windowIndex] = winA
        }
    }

    /// For each slot with exactly one window, resets its height to full screen.
    /// Removes empty slots.
    func normalizeSlots(screen: NSScreen) {
        let visible = screen.visibleFrame
        let fullH = visible.height - Config.gap * 2

        queue.sync(flags: .barrier) {
            self.slots.removeAll { $0.windows.isEmpty }

            for si in self.slots.indices where self.slots[si].windows.count == 1 {
                self.slots[si].windows[0].height = fullH
            }
            self.renumberOrders()
        }
    }

    // MARK: - Private (must be called inside barrier)

    private func indexOfSlot(containing key: ManagedWindow) -> Int? {
        slots.firstIndex { $0.windows.contains(key) }
    }

    private func equalizeHeights(inSlot slotIndex: Int, visibleHeight: CGFloat) {
        let count = CGFloat(self.slots[slotIndex].windows.count)
        guard count > 0 else { return }
        let perWindowH = (visibleHeight - Config.gap * (count + 1)) / count
        for wi in self.slots[slotIndex].windows.indices {
            self.slots[slotIndex].windows[wi].height = perWindowH
        }
    }
}
