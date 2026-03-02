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
    func scheduleReapplyWhenMouseUp(key: SnapKey, isResize: Bool) {
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
                // Accept the new size, then reflow all snapped windows.
                if let newSize = WindowSnapper.readSize(of: storedElement) {
                    SnapRegistry.shared.setSize(width: newSize.width, height: newSize.height, for: key)
                }
                let allKeys = Set(SnapRegistry.shared.allEntries().map(\.key))
                self.reapplying.formUnion(allKeys)
                WindowSnapper.reapplyAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.reapplying.subtract(allKeys)
                }
            } else {
                // Check if the window was dropped on another snapped window's zone.
                if let targetKey = WindowSnapper.findSwapTarget(for: key, window: storedElement) {
                    SnapRegistry.shared.swapSlots(key, targetKey)
                    let allKeys = Set(SnapRegistry.shared.allEntries().map(\.key))
                    self.reapplying.formUnion(allKeys)
                    WindowSnapper.reapplyAll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.reapplying.subtract(allKeys)
                    }
                } else {
                    // Restore position (and stored size) of the moved window only.
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
}
