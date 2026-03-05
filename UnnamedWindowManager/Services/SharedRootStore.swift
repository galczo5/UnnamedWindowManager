//
//  SharedRootStore.swift
//  UnnamedWindowManager
//

import AppKit

final class SharedRootStore {
    static let shared = SharedRootStore()
    private init() {
        root = RootSlot(id: UUID(), width: 0, height: 0,
                        orientation: .vertical, children: [])
    }

    var root: RootSlot
    var windowCount: Int = 0
    let queue = DispatchQueue(label: "snap.registry", attributes: .concurrent)

    func initialize(screen: NSScreen) {
        let f = screen.visibleFrame
        queue.sync(flags: .barrier) {
            self.root = RootSlot(id: UUID(), width: f.width, height: f.height,
                                 orientation: .horizontal, children: [])
            self.windowCount = 0
        }
    }

    func snapshotRoot() -> RootSlot {
        queue.sync { root }
    }
}
