//
//  SnapRegistry.swift
//  UnnamedWindowManager
//

import AppKit

final class SnapRegistry {
    static let shared = SnapRegistry()
    private init() {}

    var store: [SnapKey: SnapEntry] = [:]
    let queue = DispatchQueue(label: "snap.registry", attributes: .concurrent)

    func register(_ key: SnapKey, slot: Int, width: CGFloat, height: CGFloat) {
        queue.async(flags: .barrier) {
            self.store[key] = SnapEntry(slot: slot, width: width, height: height)
        }
    }

    func entry(for key: SnapKey) -> SnapEntry? {
        queue.sync { store[key] }
    }

    func setSize(width: CGFloat, height: CGFloat, for key: SnapKey) {
        guard let screen = NSScreen.main else { return }
        let clamped = WindowSnapper.clampSize(CGSize(width: width, height: height), screen: screen)
        queue.async(flags: .barrier) {
            self.store[key]?.width  = clamped.width
            self.store[key]?.height = clamped.height
        }
    }

    /// Copies the stored width of `key` to every other window in the same slot.
    func syncColumnWidth(for key: SnapKey) {
        queue.sync(flags: .barrier) {
            guard let entry = self.store[key] else { return }
            let slot  = entry.slot
            let width = entry.width
            for k in self.store.keys where k != key && self.store[k]?.slot == slot {
                self.store[k]?.width = width
            }
        }
    }

    /// Returns a snapshot of all entries sorted ascending by (slot, row).
    func allEntries() -> [(key: SnapKey, entry: SnapEntry)] {
        queue.sync {
            store.map { (key: $0.key, entry: $0.value) }
                 .sorted { lhs, rhs in
                     if lhs.entry.slot != rhs.entry.slot { return lhs.entry.slot < rhs.entry.slot }
                     return lhs.entry.row < rhs.entry.row
                 }
        }
    }

    func nextSlot() -> Int {
        // Row-1 windows share a slot with their row-0 partner; exclude them so
        // newly snapped windows always get a fresh horizontal column.
        queue.sync {
            let maxSlot = store.values.filter { $0.row == 0 }.map { $0.slot }.max() ?? -1
            return maxSlot + 1
        }
    }

    func remove(_ key: SnapKey) {
        queue.async(flags: .barrier) { self.store.removeValue(forKey: key) }
    }

    func isTracked(_ key: SnapKey) -> Bool {
        entry(for: key) != nil
    }
}
