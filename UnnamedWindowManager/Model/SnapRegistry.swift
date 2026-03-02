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

    /// Returns a snapshot of all entries sorted ascending by slot.
    func allEntries() -> [(key: SnapKey, entry: SnapEntry)] {
        queue.sync {
            store.map { (key: $0.key, entry: $0.value) }
                 .sorted { $0.entry.slot < $1.entry.slot }
        }
    }

    func nextSlot() -> Int {
        queue.sync { (store.values.map(\.slot).max() ?? -1) + 1 }
    }

    func remove(_ key: SnapKey) {
        queue.async(flags: .barrier) { self.store.removeValue(forKey: key) }
    }

    func isTracked(_ key: SnapKey) -> Bool {
        entry(for: key) != nil
    }
}
