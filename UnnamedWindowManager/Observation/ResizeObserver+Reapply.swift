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
                if let screen = NSScreen.main,
                   let newSize = WindowSnapper.readSize(of: storedElement) {
                    let clamped = WindowSnapper.clampSize(newSize, screen: screen)
                    ManagedSlotRegistry.shared.setWidth(clamped.width, forSlotContaining: key, screen: screen)
                }
                let allWindows = self.allTrackedWindows()
                self.reapplying.formUnion(allWindows)
                WindowSnapper.reapplyAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.verifyWidthsAfterResize(allWindows: allWindows)
                }
            } else {
                // Move: restore position. Drop zones disabled — redesign pending.
                self.reapplying.insert(key)
                WindowSnapper.reapply(window: storedElement, key: key)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.reapplying.remove(key)
                }
            }
        }

        pendingReapply[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// After reapplying widths, checks whether any app enforced a minimum width
    /// and rejected the assigned value. If so, updates the slot and reapplies all windows.
    private func verifyWidthsAfterResize(allWindows: Set<ManagedWindow>) {
        guard let screen = NSScreen.main else {
            reapplying.subtract(allWindows)
            return
        }
        let leaves = ManagedSlotRegistry.shared.allLeaves()
        var needsReapply = false

        for leaf in leaves {
            guard case .window(let w) = leaf.content,
                  let axElement = elements[w],
                  let actualWidth = WindowSnapper.readSize(of: axElement)?.width else { continue }

            if abs(actualWidth - leaf.width) > 1.0 {
                var titleRef: CFTypeRef?
                let title = AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &titleRef) == .success
                    ? (titleRef as? String ?? "<unknown>")
                    : "<unknown>"
                Logger.shared.log("[WidthVerify] \"\(title)\": stored=\(leaf.width) actual=\(actualWidth)")
                ManagedSlotRegistry.shared.setWidth(actualWidth, forSlotContaining: w, screen: screen)
                needsReapply = true
            }
        }

        if needsReapply {
            WindowSnapper.reapplyAll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.reapplying.subtract(allWindows)
        }
    }

    private func allTrackedWindows() -> Set<ManagedWindow> {
        let leaves = ManagedSlotRegistry.shared.allLeaves()
        return Set(leaves.compactMap { leaf -> ManagedWindow? in
            if case .window(let w) = leaf.content { return w }
            return nil
        })
    }
}
