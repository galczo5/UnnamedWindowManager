//
//  ManagedSlotRegistry.swift
//  UnnamedWindowManager
//

import AppKit

final class ManagedSlotRegistry {
    static let shared = ManagedSlotRegistry()
    private init() {
        // Placeholder root; call initialize(screen:) before any snapping.
        root = RootSlot(id: UUID(), width: 0, height: 0,
                        orientation: .vertical, children: [])
    }

    var root: RootSlot
    /// Global snap counter. Increments on every snap; never decremented.
    /// Leaf slots carry their insertion index as `order`; container nodes have no order.
    var windowCount: Int = 0
    let queue = DispatchQueue(label: "snap.registry", attributes: .concurrent)

    // MARK: - Init

    func initialize(screen: NSScreen) {
        let f = screen.visibleFrame
        queue.sync(flags: .barrier) {
            self.root = RootSlot(id: UUID(), width: f.width, height: f.height,
                                 orientation: .horizontal, children: [])
            self.windowCount = 0
        }
    }

    // MARK: - Snap

    func snap(_ key: WindowSlot, screen: NSScreen) {
        queue.sync(flags: .barrier) {
            self.windowCount += 1
            let newLeaf = Slot.window(WindowSlot(
                pid: key.pid, windowHash: key.windowHash,
                id: UUID(), parentId: self.root.id,
                order: self.windowCount,
                width: 0, height: 0, gaps: true
            ))

            if self.root.children.isEmpty {
                self.root.children = [newLeaf]
            } else {
                let lastOrder = self.maxLeafOrder(in: self.root)
                let orientation: Orientation = self.windowCount % 2 == 0 ? .horizontal : .vertical
                self.extractAndWrap(in: &self.root, targetOrder: lastOrder,
                                    newLeaf: newLeaf, orientation: orientation)
            }
            self.recomputeSizes(&self.root,
                                width: screen.visibleFrame.width  - Config.gap * 2,
                                height: screen.visibleFrame.height - Config.gap * 2)
        }
    }

    // MARK: - Reads

    func isTracked(_ key: WindowSlot) -> Bool {
        queue.sync { findLeafSlot(key, in: root) != nil }
    }

    /// Returns all leaf slots sorted by insertion order.
    func allLeaves() -> [Slot] {
        queue.sync {
            collectLeaves(in: root).sorted { a, b in
                if case .window(let wa) = a, case .window(let wb) = b { return wa.order < wb.order }
                return false
            }
        }
    }

    /// Returns a snapshot of the root for layout passes.
    func snapshotRoot() -> RootSlot {
        queue.sync { root }
    }

    // MARK: - Writes

    func remove(_ key: WindowSlot) {
        queue.async(flags: .barrier) {
            self.removeLeaf(key, from: &self.root)
        }
    }

    func removeAndReflow(_ key: WindowSlot, screen: NSScreen) {
        queue.sync(flags: .barrier) {
            self.removeLeaf(key, from: &self.root)
            self.recomputeSizes(&self.root,
                                width: screen.visibleFrame.width  - Config.gap * 2,
                                height: screen.visibleFrame.height - Config.gap * 2)
        }
    }

    func setWidth(_ width: CGFloat, forSlotContaining key: WindowSlot, screen: NSScreen) {
        let maxW = screen.visibleFrame.width * Config.maxWidthFraction
        let clamped = min(width, maxW)
        queue.async(flags: .barrier) {
            self.updateLeaf(key, in: &self.root) { w in
                w.width = clamped
            }
        }
    }

    // MARK: - Layout

    func recomputeSizes(_ root: inout RootSlot, width: CGFloat, height: CGFloat) {
        root.width = width
        root.height = height
        guard !root.children.isEmpty else { return }
        let n = CGFloat(root.children.count)
        let cw = root.orientation == .horizontal ? width / n : width
        let ch = root.orientation == .horizontal ? height : height / n
        for i in root.children.indices {
            recomputeSizes(&root.children[i], width: cw, height: ch)
        }
    }

    func recomputeSizes(_ slot: inout Slot, width: CGFloat, height: CGFloat) {
        switch slot {
        case .window(var w):
            w.width = width; w.height = height
            slot = .window(w)
        case .horizontal(var h):
            h.width = width; h.height = height
            let n = CGFloat(h.children.count)
            guard n > 0 else { slot = .horizontal(h); return }
            for i in h.children.indices {
                recomputeSizes(&h.children[i], width: width / n, height: height)
            }
            slot = .horizontal(h)
        case .vertical(var v):
            v.width = width; v.height = height
            let n = CGFloat(v.children.count)
            guard n > 0 else { slot = .vertical(v); return }
            for i in v.children.indices {
                recomputeSizes(&v.children[i], width: width, height: height / n)
            }
            slot = .vertical(v)
        }
    }

    // MARK: - Private tree helpers (must be called inside a barrier)

    /// Functional removal. Returns the updated subtree, or nil if this slot should be excised.
    /// Collapses single-child containers, propagating parentId to the survivor.
    private func removeFromTree(_ key: WindowSlot, slot: Slot) -> (slot: Slot?, found: Bool) {
        switch slot {
        case .window(let w):
            return w == key ? (nil, true) : (slot, false)
        case .horizontal(let h):
            var found = false
            let newChildren: [Slot] = h.children.compactMap {
                let (s, wasFound) = removeFromTree(key, slot: $0)
                if wasFound { found = true }
                return s
            }
            guard found else { return (slot, false) }
            if newChildren.isEmpty { return (nil, true) }
            if newChildren.count == 1 {
                var child = newChildren[0]; child.parentId = h.parentId
                return (child, true)
            }
            var updated = h; updated.children = newChildren
            return (.horizontal(updated), true)
        case .vertical(let v):
            var found = false
            let newChildren: [Slot] = v.children.compactMap {
                let (s, wasFound) = removeFromTree(key, slot: $0)
                if wasFound { found = true }
                return s
            }
            guard found else { return (slot, false) }
            if newChildren.isEmpty { return (nil, true) }
            if newChildren.count == 1 {
                var child = newChildren[0]; child.parentId = v.parentId
                return (child, true)
            }
            var updated = v; updated.children = newChildren
            return (.vertical(updated), true)
        }
    }

    @discardableResult
    private func removeLeaf(_ key: WindowSlot, from root: inout RootSlot) -> Bool {
        var found = false
        let newChildren: [Slot] = root.children.compactMap {
            let (newSlot, wasFound) = removeFromTree(key, slot: $0)
            if wasFound { found = true }
            return newSlot
        }
        if found { root.children = newChildren }
        return found
    }

    @discardableResult
    private func extractAndWrap(
        _ slot: inout Slot,
        targetOrder: Int,
        newLeaf: Slot,
        orientation: Orientation
    ) -> Bool {
        if case .window(let w) = slot, w.order == targetOrder {
            let containerId = UUID()
            let containerParentId = slot.parentId
            var existing = slot;  existing.parentId = containerId
            var wrapped  = newLeaf; wrapped.parentId = containerId
            slot = orientation == .horizontal
                ? .horizontal(HorizontalSlot(id: containerId, parentId: containerParentId,
                                             width: 0, height: 0, children: [existing, wrapped]))
                : .vertical(VerticalSlot(id: containerId, parentId: containerParentId,
                                         width: 0, height: 0, children: [existing, wrapped]))
            return true
        }
        switch slot {
        case .window: return false
        case .horizontal(var h):
            for i in h.children.indices {
                if extractAndWrap(&h.children[i], targetOrder: targetOrder,
                                  newLeaf: newLeaf, orientation: orientation) {
                    slot = .horizontal(h); return true
                }
            }
            return false
        case .vertical(var v):
            for i in v.children.indices {
                if extractAndWrap(&v.children[i], targetOrder: targetOrder,
                                  newLeaf: newLeaf, orientation: orientation) {
                    slot = .vertical(v); return true
                }
            }
            return false
        }
    }

    private func extractAndWrap(
        in root: inout RootSlot,
        targetOrder: Int,
        newLeaf: Slot,
        orientation: Orientation
    ) {
        for i in root.children.indices {
            if extractAndWrap(&root.children[i], targetOrder: targetOrder,
                              newLeaf: newLeaf, orientation: orientation) { return }
        }
    }

    private func maxLeafOrder(in slot: Slot) -> Int {
        switch slot {
        case .window(let w):     return w.order
        case .horizontal(let h): return h.children.map { maxLeafOrder(in: $0) }.max() ?? 0
        case .vertical(let v):   return v.children.map { maxLeafOrder(in: $0) }.max() ?? 0
        }
    }

    private func maxLeafOrder(in root: RootSlot) -> Int {
        root.children.map { maxLeafOrder(in: $0) }.max() ?? 0
    }

    private func collectLeaves(in slot: Slot) -> [Slot] {
        switch slot {
        case .window:            return [slot]
        case .horizontal(let h): return h.children.flatMap { collectLeaves(in: $0) }
        case .vertical(let v):   return v.children.flatMap { collectLeaves(in: $0) }
        }
    }

    private func collectLeaves(in root: RootSlot) -> [Slot] {
        root.children.flatMap { collectLeaves(in: $0) }
    }

    func findLeafSlot(_ key: WindowSlot, in slot: Slot) -> Slot? {
        switch slot {
        case .window(let w):
            return w == key ? slot : nil
        case .horizontal(let h):
            for child in h.children { if let f = findLeafSlot(key, in: child) { return f } }
            return nil
        case .vertical(let v):
            for child in v.children { if let f = findLeafSlot(key, in: child) { return f } }
            return nil
        }
    }

    func findLeafSlot(_ key: WindowSlot, in root: RootSlot) -> Slot? {
        root.children.compactMap { findLeafSlot(key, in: $0) }.first
    }

    @discardableResult
    private func updateLeaf(
        _ key: WindowSlot,
        in root: inout RootSlot,
        update: (inout WindowSlot) -> Void
    ) -> Bool {
        for i in root.children.indices {
            if updateLeaf(key, in: &root.children[i], update: update) { return true }
        }
        return false
    }

    @discardableResult
    private func updateLeaf(
        _ key: WindowSlot,
        in slot: inout Slot,
        update: (inout WindowSlot) -> Void
    ) -> Bool {
        switch slot {
        case .window(var w):
            guard w == key else { return false }
            update(&w); slot = .window(w); return true
        case .horizontal(var h):
            for i in h.children.indices {
                if updateLeaf(key, in: &h.children[i], update: update) {
                    slot = .horizontal(h); return true
                }
            }
            return false
        case .vertical(var v):
            for i in v.children.indices {
                if updateLeaf(key, in: &v.children[i], update: update) {
                    slot = .vertical(v); return true
                }
            }
            return false
        }
    }
}
