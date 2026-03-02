//
//  SnapRegistry.swift
//  UnnamedWindowManager
//

import Foundation

enum SnapSide: Sendable { case left, right }

struct SnapKey: Hashable, Sendable {
    let pid: pid_t
    let windowHash: UInt
}

final class SnapRegistry {
    static let shared = SnapRegistry()
    private init() {}

    private var store: [SnapKey: SnapSide] = [:]
    private let queue = DispatchQueue(label: "snap.registry", attributes: .concurrent)

    func register(_ key: SnapKey, side: SnapSide) {
        queue.async(flags: .barrier) { self.store[key] = side }
    }

    func side(for key: SnapKey) -> SnapSide? {
        queue.sync { store[key] }
    }

    func remove(_ key: SnapKey) {
        queue.async(flags: .barrier) { self.store.removeValue(forKey: key) }
    }

    func isTracked(_ key: SnapKey) -> Bool {
        side(for: key) != nil
    }
}
