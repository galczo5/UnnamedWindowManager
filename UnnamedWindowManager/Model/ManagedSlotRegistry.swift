//
//  ManagedSlotRegistry.swift
//  UnnamedWindowManager
//

import AppKit

final class ManagedSlotRegistry {
    static let shared = ManagedSlotRegistry()
    private init() {}

    var slots: [ManagedSlot] = []
    let queue = DispatchQueue(label: "snap.registry", attributes: .concurrent)

    // MARK: - Reads

    /// Returns a snapshot copy of all slots.
    func allSlots() -> [ManagedSlot] {
        queue.sync { slots }
    }

    /// Returns the slot index containing this window, or nil.
    func slotIndex(for key: ManagedWindow) -> Int? {
        queue.sync {
            slots.firstIndex { slot in slot.windows.contains(key) }
        }
    }

    /// Returns the (slotIndex, windowIndex) for this window, or nil.
    func findWindow(_ key: ManagedWindow) -> (slotIndex: Int, windowIndex: Int)? {
        queue.sync {
            for (si, slot) in slots.enumerated() {
                if let wi = slot.windows.firstIndex(of: key) {
                    return (si, wi)
                }
            }
            return nil
        }
    }

    func isTracked(_ key: ManagedWindow) -> Bool {
        slotIndex(for: key) != nil
    }

    // MARK: - Writes

    /// Registers a new window as a new slot appended to the right.
    func register(_ key: ManagedWindow, width: CGFloat, height: CGFloat) {
        queue.async(flags: .barrier) {
            let window = ManagedWindow(pid: key.pid, windowHash: key.windowHash, height: height)
            self.slots.append(ManagedSlot(width: width, windows: [window]))
        }
    }

    /// Removes a window from its slot. Removes the slot if it becomes empty.
    func remove(_ key: ManagedWindow) {
        queue.async(flags: .barrier) {
            for si in self.slots.indices {
                if let wi = self.slots[si].windows.firstIndex(of: key) {
                    self.slots[si].windows.remove(at: wi)
                    if self.slots[si].windows.isEmpty {
                        self.slots.remove(at: si)
                    }
                    return
                }
            }
        }
    }

    /// Updates the height of a specific window (clamped).
    func setHeight(_ height: CGFloat, for key: ManagedWindow, screen: NSScreen) {
        let maxH = screen.visibleFrame.height * Config.maxHeightFraction - Config.gap * 2
        let clamped = min(height, maxH)
        queue.async(flags: .barrier) {
            for si in self.slots.indices {
                if let wi = self.slots[si].windows.firstIndex(of: key) {
                    self.slots[si].windows[wi].height = clamped
                    return
                }
            }
        }
    }

    /// Updates the width of the slot containing this window (clamped).
    func setWidth(_ width: CGFloat, forSlotContaining key: ManagedWindow, screen: NSScreen) {
        let maxW = screen.visibleFrame.width * Config.maxWidthFraction
        let clamped = min(width, maxW)
        queue.async(flags: .barrier) {
            if let si = self.slots.firstIndex(where: { $0.windows.contains(key) }) {
                self.slots[si].width = clamped
            }
        }
    }
}
