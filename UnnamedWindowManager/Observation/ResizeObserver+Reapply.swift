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
    func scheduleReapplyWhenMouseUp(key: WindowSlot, isResize: Bool) {
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
                guard let screen = NSScreen.main,
                      let axElement = self.elements[key],
                      let actualSize = readSize(of: axElement) else { return }

                let allWindows = self.allTrackedWindows()
                self.reapplying.formUnion(allWindows)
                SnapService.shared.resize(key: key, actualSize: actualSize, screen: screen)
                ReapplyHandler.reapplyAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.reapplying.subtract(allWindows)
                }
            } else {
                // Move: swap if dragged onto another managed window, otherwise restore.
                if let swapTarget = ReapplyHandler.findSwapTarget(forKey: key) {
                    let allWindows = self.allTrackedWindows()
                    self.reapplying.formUnion(allWindows)
                    SnapService.shared.swap(key, swapTarget)
                    ReapplyHandler.reapplyAll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.reapplying.subtract(allWindows)
                    }
                } else {
                    self.reapplying.insert(key)
                    ReapplyHandler.reapply(window: storedElement, key: key)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.reapplying.remove(key)
                    }
                }
            }
        }

        pendingReapply[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func allTrackedWindows() -> Set<WindowSlot> {
        let leaves = SnapService.shared.allLeaves()
        return Set(leaves.compactMap { leaf -> WindowSlot? in
            if case .window(let w) = leaf { return w }
            return nil
        })
    }
}
