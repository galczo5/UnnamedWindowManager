// Read-only traversal of the slot tree: finding, collecting, and inspecting leaves.
struct SlotTreeQueryService {

    /// Returns `true` if `key` exists anywhere in the tree.
    func isTracked(_ key: WindowSlot, in root: TilingRootSlot) -> Bool {
        return findLeafSlot(key, in: root) != nil
    }

    /// Returns every window leaf in the tree, in depth-first order.
    func allLeaves(in root: TilingRootSlot) -> [Slot] {
        return root.children.flatMap { collectLeaves(in: $0) }
    }

    /// Returns the `Slot` wrapping `key`, or `nil` if it is not in the tree.
    func findLeafSlot(_ key: WindowSlot, in root: TilingRootSlot) -> Slot? {
        return root.children.compactMap { findLeafSlot(key, in: $0) }.first
    }

    /// Returns the highest `order` value among all window leaves in the tree.
    func maxLeafOrder(in root: TilingRootSlot) -> Int {
        return root.children.map { maxLeafOrder(in: $0) }.max() ?? 0
    }

    /// Returns the orientation of the container that directly holds `key`, or `nil` if not found.
    func findParentOrientation(of key: WindowSlot, in root: TilingRootSlot) -> Orientation? {
        if root.children.contains(where: {
            if case .window(let w) = $0 { return w == key }; return false
        }) { return root.orientation }
        for child in root.children {
            if let o = findParentOrientation(of: key, in: child) { return o }
        }
        return nil
    }

    // MARK: - Private recursive helpers

    private func findLeafSlot(_ key: WindowSlot, in slot: Slot) -> Slot? {
        switch slot {
        case .window(let w):
            return w == key ? slot : nil
        case .split(let s):
            for child in s.children { if let f = findLeafSlot(key, in: child) { return f } }
            return nil
        case .stacking:
            fatalError("StackingSlot encountered in tiling tree traversal — stacking slots are not supported by SlotTreeQueryService")
        }
    }

    private func collectLeaves(in slot: Slot) -> [Slot] {
        switch slot {
        case .window:        return [slot]
        case .split(let s):  return s.children.flatMap { collectLeaves(in: $0) }
        case .stacking:
            fatalError("StackingSlot encountered in tiling tree traversal — stacking slots are not supported by SlotTreeQueryService")
        }
    }

    private func maxLeafOrder(in slot: Slot) -> Int {
        switch slot {
        case .window(let w): return w.order
        case .split(let s):  return s.children.map { maxLeafOrder(in: $0) }.max() ?? 0
        case .stacking:
            fatalError("StackingSlot encountered in tiling tree traversal — stacking slots are not supported by SlotTreeQueryService")
        }
    }

    private func findParentOrientation(of key: WindowSlot, in slot: Slot) -> Orientation? {
        switch slot {
        case .window: return nil
        case .split(let s):
            if s.children.contains(where: {
                if case .window(let w) = $0 { return w == key }; return false
            }) { return s.orientation }
            for child in s.children { if let o = findParentOrientation(of: key, in: child) { return o } }
            return nil
        case .stacking:
            fatalError("StackingSlot encountered in tiling tree traversal — stacking slots are not supported by SlotTreeQueryService")
        }
    }
}
