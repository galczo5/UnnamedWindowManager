//
//  SnapRegistry.swift
//  UnnamedWindowManager
//

import Foundation

struct SnapKey: Hashable, Sendable {
    let pid: pid_t
    let windowHash: UInt
}

struct SnapEntry {
    let slot: Int
    var width: CGFloat
    var height: CGFloat
}

final class SnapRegistry {
    static let shared = SnapRegistry()
    private init() {}

    private var store: [SnapKey: SnapEntry] = [:]
    private let queue = DispatchQueue(label: "snap.registry", attributes: .concurrent)

    func register(_ key: SnapKey, slot: Int, width: CGFloat, height: CGFloat) {
        queue.async(flags: .barrier) {
            self.store[key] = SnapEntry(slot: slot, width: width, height: height)
        }
    }

    func entry(for key: SnapKey) -> SnapEntry? {
        queue.sync { store[key] }
    }

    func setSize(width: CGFloat, height: CGFloat, for key: SnapKey) {
        queue.async(flags: .barrier) {
            self.store[key]?.width = width
            self.store[key]?.height = height
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
