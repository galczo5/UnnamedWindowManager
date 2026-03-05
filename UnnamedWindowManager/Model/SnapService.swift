//
//  SnapService.swift
//  UnnamedWindowManager
//

import AppKit

final class SnapService {
    static let shared = SnapService()
    private init() {}

    private let store    = SharedRootStore.shared
    private let tree     = SlotTreeService()
    private let position = PositionService()

    // MARK: - Queries

    func isTracked(_ key: WindowSlot) -> Bool {
        store.queue.sync { tree.isTracked(key, in: store.root) }
    }

    func allLeaves() -> [Slot] {
        store.queue.sync {
            tree.allLeaves(in: store.root).sorted { a, b in
                if case .window(let wa) = a, case .window(let wb) = b { return wa.order < wb.order }
                return false
            }
        }
    }

    // MARK: - Snap / unsnap

    func snap(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            store.windowCount += 1
            let newLeaf = Slot.window(WindowSlot(
                pid: key.pid, windowHash: key.windowHash,
                id: UUID(), parentId: store.root.id,
                order: store.windowCount,
                width: 0, height: 0, gaps: true
            ))
            if store.root.children.isEmpty {
                store.root.children = [newLeaf]
            } else {
                let lastOrder = tree.maxLeafOrder(in: store.root)
                let orientation: Orientation = store.windowCount % 2 == 0 ? .horizontal : .vertical
                tree.extractAndWrap(in: &store.root, targetOrder: lastOrder,
                                    newLeaf: newLeaf, orientation: orientation)
            }
            position.recomputeSizes(&store.root,
                                    width: screen.visibleFrame.width  - Config.gap * 2,
                                    height: screen.visibleFrame.height - Config.gap * 2)
        }
    }

    func remove(_ key: WindowSlot) {
        store.queue.async(flags: .barrier) {
            self.tree.removeLeaf(key, from: &self.store.root)
        }
    }

    func removeAndReflow(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            tree.removeLeaf(key, from: &store.root)
            position.recomputeSizes(&store.root,
                                    width: screen.visibleFrame.width  - Config.gap * 2,
                                    height: screen.visibleFrame.height - Config.gap * 2)
        }
    }

    func setWidth(_ width: CGFloat, forSlotContaining key: WindowSlot, screen: NSScreen) {
        let clamped = position.clampedWidth(width, screen: screen)
        store.queue.async(flags: .barrier) {
            self.tree.updateLeaf(key, in: &self.store.root) { w in w.width = clamped }
        }
    }

    func swap(_ keyA: WindowSlot, _ keyB: WindowSlot) {
        store.queue.sync(flags: .barrier) {
            tree.swap(keyA, keyB, in: &store.root)
        }
    }
}
