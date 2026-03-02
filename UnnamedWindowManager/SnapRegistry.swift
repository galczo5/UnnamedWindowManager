//
//  SnapRegistry.swift
//  UnnamedWindowManager
//

import Foundation

struct SnapKey: Hashable, Sendable {
    let pid: pid_t
    let windowHash: UInt
}

final class SnapRegistry {
    static let shared = SnapRegistry()
    private init() {}

    private var store: [SnapKey: Int] = [:]
    private let queue = DispatchQueue(label: "snap.registry", attributes: .concurrent)

    func register(_ key: SnapKey, slot: Int) {
        queue.async(flags: .barrier) { self.store[key] = slot }
    }

    func slot(for key: SnapKey) -> Int? {
        queue.sync { store[key] }
    }

    func nextSlot() -> Int {
        queue.sync { (store.values.max() ?? -1) + 1 }
    }

    func remove(_ key: SnapKey) {
        queue.async(flags: .barrier) { self.store.removeValue(forKey: key) }
    }

    func isTracked(_ key: SnapKey) -> Bool {
        slot(for: key) != nil
    }
}
