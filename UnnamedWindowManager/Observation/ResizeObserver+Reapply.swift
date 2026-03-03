//
//  ResizeObserver+Reapply.swift
//  UnnamedWindowManager
//

import AppKit

extension ResizeObserver {

    /// Polls every 50 ms until no mouse button is held, then reapplies the snap.
    /// Any in-progress poll for the same key is cancelled before scheduling a new one.
    /// - Parameter isResize: true when triggered by a resize notification — accepts the
    ///   new size and reflows all snapped windows; false for move — restores position only.
    func scheduleReapplyWhenMouseUp(key: ManagedWindow, isResize: Bool) {
        pendingReapply[key]?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReapply.removeValue(forKey: key)

            if NSEvent.pressedMouseButtons != 0 {
                self.scheduleReapplyWhenMouseUp(key: key, isResize: isResize)
                return
            }

            self.hideSwapOverlay()

            guard !self.reapplying.contains(key),
                  let storedElement = self.elements[key] else { return }

            if isResize {
                guard let screen = NSScreen.main else { return }
                // Accept the new size, then reflow all snapped windows.
                if let newSize = WindowSnapper.readSize(of: storedElement) {
                    ManagedSlotRegistry.shared.setHeight(newSize.height, for: key, screen: screen)
                    ManagedSlotRegistry.shared.setWidth(newSize.width, forSlotContaining: key, screen: screen)
                }
                let allWindows = self.allTrackedWindows()
                self.reapplying.formUnion(allWindows)
                WindowSnapper.reapplyAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.reapplying.subtract(allWindows)
                }
            } else {
                guard let screen = NSScreen.main else { return }
                // Check if the window was dropped on another snapped window's zone.
                guard let sourceSlotIndex = ManagedSlotRegistry.shared.slotIndex(for: key) else { return }
                if let target = WindowSnapper.findDropTarget(forWindowIn: sourceSlotIndex) {
                    switch target.zone {
                    case .left:
                        ManagedSlotRegistry.shared.moveSlot(containing: key, before: target.slotIndex)
                    case .right:
                        ManagedSlotRegistry.shared.moveSlot(containing: key, after: target.slotIndex)
                    case .center:
                        ManagedSlotRegistry.shared.swapSlots(sourceSlotIndex, target.slotIndex)
                    case .bottom:
                        ManagedSlotRegistry.shared.splitVertical(key, intoSlot: target.slotIndex, screen: screen)
                    }
                    ManagedSlotRegistry.shared.normalizeSlots(screen: screen)
                    let allWindows = self.allTrackedWindows()
                    self.reapplying.formUnion(allWindows)
                    WindowSnapper.reapplyAll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.reapplying.subtract(allWindows)
                    }
                } else {
                    // Restore position (and stored size) of the moved window only.
                    ManagedSlotRegistry.shared.normalizeSlots(screen: screen)
                    self.reapplying.insert(key)
                    WindowSnapper.reapply(window: storedElement, key: key)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.reapplying.remove(key)
                    }
                }
            }
        }

        pendingReapply[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Collects all tracked ManagedWindow keys from the current slots.
    private func allTrackedWindows() -> Set<ManagedWindow> {
        let slots = ManagedSlotRegistry.shared.allSlots()
        var keys = Set<ManagedWindow>()
        for slot in slots {
            for w in slot.windows {
                keys.insert(w)
            }
        }
        return keys
    }
}
