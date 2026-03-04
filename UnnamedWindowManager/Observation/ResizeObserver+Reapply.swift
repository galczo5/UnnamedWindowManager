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
                // Accept the new width; height is restored to the stored value.
                if let screen = NSScreen.main,
                   let newSize = WindowSnapper.readSize(of: storedElement) {
                    let clamped = WindowSnapper.clampSize(newSize, screen: screen)
                    ManagedSlotRegistry.shared.setWidth(clamped.width, forSlotContaining: key, screen: screen)
                }
                let allWindows = self.allTrackedWindows()
                self.reapplying.formUnion(allWindows)
                WindowSnapper.reapplyAll()
                // After 100 ms, verify each slot's actual width. If an app enforced a
                // minimum and rejected the assigned width, reconcile all slots to that width.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.verifyWidthsAfterResize(allWindows: allWindows)
                }
            } else {
                guard let screen = NSScreen.main else { return }
                // Check if the window was dropped on another snapped window's zone.
                guard let sourceSlotIndex = ManagedSlotRegistry.shared.slotIndex(for: key) else { return }
                if let target = WindowSnapper.findDropTarget(forWindowIn: sourceSlotIndex) {
                    switch target.zone {
                    case .left:
                        ManagedSlotRegistry.shared.insertSlotBefore(key, targetSlot: target.slotIndex, screen: screen)
                    case .right:
                        ManagedSlotRegistry.shared.insertSlotAfter(key, targetSlot: target.slotIndex, screen: screen)
                    case .top:
                        ManagedSlotRegistry.shared.insertWindowTop(key, intoSlot: target.slotIndex, screen: screen)
                    case .bottom:
                        ManagedSlotRegistry.shared.insertWindowBottom(key, intoSlot: target.slotIndex, screen: screen)
                    case .center:
                        if let src = ManagedSlotRegistry.shared.findWindow(key) {
                            ManagedSlotRegistry.shared.swapWindows(
                                (slotIndex: src.slotIndex, windowIndex: src.windowIndex),
                                with: (slotIndex: target.slotIndex, windowIndex: target.windowIndex)
                            )
                        }
                    }
                    ManagedSlotRegistry.shared.normalizeSlots(screen: screen)
                    let allWindows = self.allTrackedWindows()
                    self.reapplying.formUnion(allWindows)
                    WindowSnapper.reapplyAll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.verifyWidthsAfterResize(allWindows: allWindows)
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

    /// After reapplying widths, checks whether any app enforced a minimum width
    /// and rejected the assigned value. If so, updates the slot to the actual width
    /// and reapplies all windows so every slot in the layout is consistent.
    private func verifyWidthsAfterResize(allWindows: Set<ManagedWindow>) {
        guard let screen = NSScreen.main else {
            reapplying.subtract(allWindows)
            return
        }
        let slots = ManagedSlotRegistry.shared.allSlots()
        var needsReapply = false

        for slot in slots {
            for window in slot.windows {
                guard let axElement = elements[window],
                      let actualWidth = WindowSnapper.readSize(of: axElement)?.width else { continue }

                if abs(actualWidth - slot.width) > 1.0 {
                    var titleRef: CFTypeRef?
                    let title = AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &titleRef) == .success
                        ? (titleRef as? String ?? "<unknown>")
                        : "<unknown>"
                    Logger.shared.log("[WidthVerify] \"\(title)\": stored=\(slot.width) actual=\(actualWidth)")
                    ManagedSlotRegistry.shared.setWidth(actualWidth, forSlotContaining: window, screen: screen)
                    needsReapply = true
                    break  // All windows in the slot share the same width; one correction is enough
                }
            }
        }

        if needsReapply {
            WindowSnapper.reapplyAll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.reapplying.subtract(allWindows)
        }
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
