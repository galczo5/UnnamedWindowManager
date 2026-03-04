//
//  ManagedSlotRegistry.swift
//  UnnamedWindowManager
//

import AppKit

final class ManagedSlotRegistry {
    static let shared = ManagedSlotRegistry()
    private init() {
        // Placeholder root; call initialize(screen:) before any snapping.
        root = ManagedSlot(order: 0, width: 0, height: 0,
                           orientation: .vertical, content: .slots([]))
    }

    var root: ManagedSlot
    /// Global snap counter. Increments on every snap; never decremented.
    /// Leaf slots carry their insertion index as `order`; container nodes carry 0.
    var windowCount: Int = 0
    let queue = DispatchQueue(label: "snap.registry", attributes: .concurrent)

    // MARK: - Init

    func initialize(screen: NSScreen) {
        let f = screen.visibleFrame
        queue.sync(flags: .barrier) {
            self.root = ManagedSlot(order: 0, width: f.width, height: f.height,
                                    orientation: .horizontal, content: .slots([]))
            self.windowCount = 0
        }
    }

    // MARK: - Snap

    func snap(_ key: ManagedWindow, screen: NSScreen) {
        queue.sync(flags: .barrier) {
            self.windowCount += 1
            let newLeaf = ManagedSlot(
                order: self.windowCount,
                width: 0, height: 0,
                orientation: .horizontal,
                content: .window(ManagedWindow(pid: key.pid, windowHash: key.windowHash,
                                               height: 0, width: 0))
            )

            if case .slots(let children) = self.root.content, children.isEmpty {
                self.root.content = .slots([newLeaf])
            } else {
                let lastOrder = self.maxLeafOrder(in: self.root)
                let orientation: Orientation = self.windowCount % 2 == 0 ? .horizontal : .vertical
                self.extractAndWrap(&self.root, targetOrder: lastOrder,
                                    newLeaf: newLeaf, orientation: orientation)
            }
            self.recomputeSizes(&self.root,
                                width: screen.visibleFrame.width,
                                height: screen.visibleFrame.height)
        }
    }

    // MARK: - Reads

    func isTracked(_ key: ManagedWindow) -> Bool {
        queue.sync { findLeafSlot(key, in: root) != nil }
    }

    /// Returns the leaf slot's `order` (insertion index), or nil if not found.
    func slotIndex(for key: ManagedWindow) -> Int? {
        queue.sync { findLeafSlot(key, in: root)?.order }
    }

    /// Returns (order, 0) for the leaf holding this window. windowIndex is always 0.
    func findWindow(_ key: ManagedWindow) -> (slotIndex: Int, windowIndex: Int)? {
        queue.sync {
            guard let leaf = findLeafSlot(key, in: root) else { return nil }
            return (leaf.order, 0)
        }
    }

    /// Returns all leaf slots sorted by insertion order.
    func allLeaves() -> [ManagedSlot] {
        queue.sync { collectLeaves(in: root).sorted { $0.order < $1.order } }
    }

    /// Returns a snapshot of the root slot for layout passes.
    func snapshotRoot() -> ManagedSlot {
        queue.sync { root }
    }

    // MARK: - Writes

    func remove(_ key: ManagedWindow) {
        queue.async(flags: .barrier) {
            self.removeLeaf(key, from: &self.root)
        }
    }

    func removeAndReflow(_ key: ManagedWindow, screen: NSScreen) {
        queue.sync(flags: .barrier) {
            self.removeLeaf(key, from: &self.root)
            self.recomputeSizes(&self.root,
                                width: screen.visibleFrame.width,
                                height: screen.visibleFrame.height)
        }
    }

    func setHeight(_ height: CGFloat, for key: ManagedWindow, screen: NSScreen) {
        let maxH = screen.visibleFrame.height * Config.maxHeightFraction - Config.gap * 2
        let clamped = min(height, maxH)
        queue.async(flags: .barrier) {
            self.updateLeaf(key, in: &self.root) { slot in
                slot.height = clamped
                if case .window(var w) = slot.content {
                    w.height = clamped
                    slot.content = .window(w)
                }
            }
        }
    }

    func setWidth(_ width: CGFloat, forSlotContaining key: ManagedWindow, screen: NSScreen) {
        let maxW = screen.visibleFrame.width * Config.maxWidthFraction
        let clamped = min(width, maxW)
        queue.async(flags: .barrier) {
            self.updateLeaf(key, in: &self.root) { slot in
                slot.width = clamped
                if case .window(var w) = slot.content {
                    w.width = clamped
                    slot.content = .window(w)
                }
            }
        }
    }

    // MARK: - Layout

    func recomputeSizes(_ slot: inout ManagedSlot, width: CGFloat, height: CGFloat) {
        slot.width  = width
        slot.height = height
        guard case .slots(var children) = slot.content, !children.isEmpty else { return }

        let n = CGFloat(children.count)
        let cw: CGFloat
        let ch: CGFloat
        if slot.orientation == .horizontal {
            cw = (width  - Config.gap * (n + 1)) / n
            ch =  height - Config.gap * 2
        } else {
            cw =  width  - Config.gap * 2
            ch = (height - Config.gap * (n + 1)) / n
        }
        for i in children.indices {
            recomputeSizes(&children[i], width: cw, height: ch)
        }
        slot.content = .slots(children)
    }

    // MARK: - Private tree helpers (must be called inside a barrier)

    @discardableResult
    private func removeLeaf(_ key: ManagedWindow, from slot: inout ManagedSlot) -> Bool {
        if case .window(let w) = slot.content, w == key { return true }
        guard case .slots(var children) = slot.content else { return false }
        for i in children.indices {
            if removeLeaf(key, from: &children[i]) {
                children.remove(at: i)
                if children.count == 1 {
                    slot = children[0]   // collapse single-child container
                } else {
                    slot.content = .slots(children)
                }
                return true
            }
        }
        return false
    }

    @discardableResult
    private func extractAndWrap(
        _ slot: inout ManagedSlot,
        targetOrder: Int,
        newLeaf: ManagedSlot,
        orientation: Orientation
    ) -> Bool {
        if case .window = slot.content, slot.order == targetOrder {
            let existing = slot
            slot = ManagedSlot(order: 0, width: 0, height: 0,
                               orientation: orientation,
                               content: .slots([existing, newLeaf]))
            return true
        }
        if case .slots(var children) = slot.content {
            for i in children.indices {
                if extractAndWrap(&children[i], targetOrder: targetOrder,
                                  newLeaf: newLeaf, orientation: orientation) {
                    slot.content = .slots(children)
                    return true
                }
            }
        }
        return false
    }

    private func maxLeafOrder(in slot: ManagedSlot) -> Int {
        switch slot.content {
        case .window:             return slot.order
        case .slots(let children): return children.map { maxLeafOrder(in: $0) }.max() ?? 0
        }
    }

    private func collectLeaves(in slot: ManagedSlot) -> [ManagedSlot] {
        switch slot.content {
        case .window:              return [slot]
        case .slots(let children): return children.flatMap { collectLeaves(in: $0) }
        }
    }

    private func findLeafSlot(_ key: ManagedWindow, in slot: ManagedSlot) -> ManagedSlot? {
        switch slot.content {
        case .window(let w):
            return w == key ? slot : nil
        case .slots(let children):
            for child in children {
                if let found = findLeafSlot(key, in: child) { return found }
            }
            return nil
        }
    }

    @discardableResult
    private func updateLeaf(
        _ key: ManagedWindow,
        in slot: inout ManagedSlot,
        update: (inout ManagedSlot) -> Void
    ) -> Bool {
        if case .window(let w) = slot.content, w == key {
            update(&slot)
            return true
        }
        if case .slots(var children) = slot.content {
            for i in children.indices {
                if updateLeaf(key, in: &children[i], update: update) {
                    slot.content = .slots(children)
                    return true
                }
            }
        }
        return false
    }
}
