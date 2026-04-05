# Plan: 08_scrolling_root_methods — Move scrolling operations onto ScrollingRootSlot

## Checklist

- [ ] Create `Model/ScrollingRoot/` directory
- [ ] Move `ScrollingRootSlot.swift` into `Model/ScrollingRoot/`
- [ ] Add query methods: `containsWindow`, `isCenterWindow`, `allWindowSlots`, `location`
- [ ] Add mutation methods: `addWindow`, `removeWindow`, `scrollLeft`, `scrollRight`, `scrollToWindow`, `swapWindows`, `updateCenterFraction`
- [ ] Add sizing method: `recomputeSizes`
- [ ] Add helper: `appendToSide`
- [ ] Move `ScrollingSlotLocation` enum into `Model/ScrollingRoot/`
- [ ] Update `ScrollingRootStore` to call root methods
- [ ] Delete `ScrollingPositionService.swift`
- [ ] Update all external references
- [ ] Verify build and all functionality

---

## Context / Problem

Similar to the tiling side, operations on `ScrollingRootSlot` are spread across:
- `ScrollingRootStore` — contains most mutation methods (460 lines, mixing store access with tree logic)
- `ScrollingPositionService` — recomputeSizes (62 lines)

The `ScrollingRootStore` is the worst offender: it's a 460-line class mixing thread-safe store access with pure tree manipulations. Every method follows the same pattern:

```swift
func scrollRight(screen: NSScreen) -> WindowSlot? {
    store.queue.sync(flags: .barrier) {
        guard let id = visibleScrollingRootID(),
              case .scrolling(var root) = store.roots[id] else { return nil }
        // ... 20 lines of pure tree manipulation ...
        store.roots[id] = .scrolling(root)
        return result
    }
}
```

After this refactor, the tree manipulation becomes `root.scrollRight()` and the store handles only the locking and root lookup.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Model/ScrollingRoot/` | **New directory** |
| `UnnamedWindowManager/Model/ScrollingRoot/ScrollingRootSlot.swift` | **Move + expand** — from `Model/ScrollingRootSlot.swift`, add all methods |
| `UnnamedWindowManager/Model/ScrollingRoot/ScrollingSlotLocation.swift` | **New file** — move enum from `ScrollingRootStore.swift` |
| `UnnamedWindowManager/Model/ScrollingRootSlot.swift` | **Delete** (moved) |
| `UnnamedWindowManager/Services/Scrolling/ScrollingPositionService.swift` | **Delete** |
| `UnnamedWindowManager/Services/Scrolling/ScrollingRootStore.swift` | Modify — drastically simplify, call root methods |
| `UnnamedWindowManager/Services/Scrolling/ScrollingResizeService.swift` | Modify — if it calls deleted services |
| `UnnamedWindowManager/Services/Scrolling/ScrollingFocusService.swift` | Modify — if it references changed signatures |
| `UnnamedWindowManager/Services/Scrolling/ScrollingLayoutService.swift` | Modify — if it references deleted services |

---

## Implementation Steps

### 1. Add query methods to ScrollingRootSlot

Move the private query helpers from `ScrollingRootStore` into public methods on the struct:

```swift
struct ScrollingRootSlot {
    var id: UUID
    var size: CGSize
    var centerWidthFraction: CGFloat? = nil
    var left: Slot?
    var center: Slot
    var right: Slot?

    // MARK: - Query

    func containsWindow(_ key: WindowSlot) -> Bool {
        allWindowSlots().contains { $0.windowHash == key.windowHash }
    }

    func isCenterWindow(_ key: WindowSlot) -> Bool {
        switch center {
        case .window(let w):   return w.windowHash == key.windowHash
        case .stacking(let s): return s.children.contains { $0.windowHash == key.windowHash }
        default:               return false
        }
    }

    func allWindowSlots() -> [WindowSlot] {
        var slots: [WindowSlot] = []
        func collect(_ slot: Slot) {
            switch slot {
            case .window(let w):    slots.append(w)
            case .stacking(let s): slots.append(contentsOf: s.children)
            default: break
            }
        }
        if let left  { collect(left) }
        collect(center)
        if let right { collect(right) }
        return slots
    }

    func location(of key: WindowSlot) -> ScrollingSlotLocation? {
        if isCenterWindow(key) { return .center }
        if case .stacking(let s) = left,
           let idx = s.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
            return .left(index: idx, count: s.children.count)
        }
        if case .stacking(let s) = right,
           let idx = s.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
            return .right(index: idx, count: s.children.count)
        }
        return nil
    }
}
```

### 2. Add mutation methods

Move the tree manipulation parts (without store access / barrier blocks) into `mutating` methods:

```swift
    // MARK: - Mutation

    mutating func addWindow(_ key: WindowSlot, screenArea: CGSize) {
        let newWin = WindowSlot(pid: key.pid, windowHash: key.windowHash,
                                id: UUID(), parentId: id, order: 0,
                                size: .zero, gaps: true,
                                preTileOrigin: key.preTileOrigin, preTileSize: key.preTileSize)
        if case .window(let oldCenter) = center {
            appendToSide(oldCenter, side: &left, align: .right)
        }
        center = .window(newWin)
        if let preTileSize = key.preTileSize, preTileSize.width > 0 {
            centerWidthFraction = Self.clampedCenterFraction(
                proposedWidth: preTileSize.width, screenWidth: screenArea.width)
        }
    }

    /// Returns the new center WindowSlot, or nil if right side is empty.
    mutating func scrollRight(screenArea: CGSize) -> WindowSlot? {
        guard case .stacking(var rightStack) = right else { return nil }
        let newCenterWin = rightStack.children.removeLast()
        right = rightStack.children.isEmpty ? nil : .stacking(rightStack)
        if case .window(let oldCenter) = center {
            appendToSide(oldCenter, side: &left, align: .right)
        }
        center = .window(newCenterWin)
        if newCenterWin.size.width > 0 {
            centerWidthFraction = Self.clampedCenterFraction(
                proposedWidth: newCenterWin.size.width, screenWidth: screenArea.width)
        }
        return newCenterWin
    }

    /// Returns the new center WindowSlot, or nil if left side is empty.
    mutating func scrollLeft(screenArea: CGSize) -> WindowSlot? {
        guard case .stacking(var leftStack) = left else { return nil }
        let newCenterWin = leftStack.children.removeLast()
        left = leftStack.children.isEmpty ? nil : .stacking(leftStack)
        if case .window(let oldCenter) = center {
            appendToSide(oldCenter, side: &right, align: .left)
        }
        center = .window(newCenterWin)
        if newCenterWin.size.width > 0 {
            centerWidthFraction = Self.clampedCenterFraction(
                proposedWidth: newCenterWin.size.width, screenWidth: screenArea.width)
        }
        return newCenterWin
    }

    /// Removes a window from any zone. Returns the stored WindowSlot if found.
    /// If removing center with no sides remaining, returns the center (caller should remove the root).
    /// Sets `rootExhausted` to true when the root should be deleted.
    mutating func removeWindow(_ key: WindowSlot, screenArea: CGSize) -> (removed: WindowSlot?, rootExhausted: Bool) {
        // Center?
        if case .window(let c) = center, c.windowHash == key.windowHash {
            if case .stacking(var leftStack) = left {
                let promoted = leftStack.children.removeLast()
                left = leftStack.children.isEmpty ? nil : .stacking(leftStack)
                center = .window(promoted)
            } else if case .stacking(var rightStack) = right {
                let promoted = rightStack.children.removeLast()
                right = rightStack.children.isEmpty ? nil : .stacking(rightStack)
                center = .window(promoted)
            } else {
                return (c, true)
            }
            return (c, false)
        }
        // Left?
        if case .stacking(var leftStack) = left,
           let idx = leftStack.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
            let removed = leftStack.children.remove(at: idx)
            left = leftStack.children.isEmpty ? nil : .stacking(leftStack)
            return (removed, false)
        }
        // Right?
        if case .stacking(var rightStack) = right,
           let idx = rightStack.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
            let removed = rightStack.children.remove(at: idx)
            right = rightStack.children.isEmpty ? nil : .stacking(rightStack)
            return (removed, false)
        }
        return (nil, false)
    }

    /// Batch-scrolls so that `key` becomes center. Returns the new center.
    mutating func scrollToWindow(_ key: WindowSlot, screenArea: CGSize) -> WindowSlot? {
        guard let loc = location(of: key) else { return nil }
        guard case .window(let oldCenter) = center else { return nil }
        let target: WindowSlot
        switch loc {
        case .center: return nil
        case .right(let index, _):
            guard case .stacking(var stack) = right else { return nil }
            let removed = Array(stack.children[index...])
            stack.children.removeSubrange(index...)
            right = stack.children.isEmpty ? nil : .stacking(stack)
            appendToSide(oldCenter, side: &left, align: .right)
            for win in removed.dropFirst().reversed() {
                appendToSide(win, side: &left, align: .right)
            }
            target = removed.first!
        case .left(let index, _):
            guard case .stacking(var stack) = left else { return nil }
            let removed = Array(stack.children[index...])
            stack.children.removeSubrange(index...)
            left = stack.children.isEmpty ? nil : .stacking(stack)
            appendToSide(oldCenter, side: &right, align: .left)
            for win in removed.dropFirst().reversed() {
                appendToSide(win, side: &right, align: .left)
            }
            target = removed.first!
        }
        center = .window(target)
        if target.size.width > 0 {
            centerWidthFraction = Self.clampedCenterFraction(
                proposedWidth: target.size.width, screenWidth: screenArea.width)
        }
        return target
    }

    mutating func swapWindows(_ direction: FocusDirection) -> WindowSlot? {
        let moved: WindowSlot
        switch direction {
        case .left:
            guard case .stacking(var leftStack) = left else { return nil }
            moved = leftStack.children.removeLast()
            left = leftStack.children.isEmpty ? nil : .stacking(leftStack)
            appendToSide(moved, side: &right, align: .left)
        case .right:
            guard case .stacking(var rightStack) = right else { return nil }
            moved = rightStack.children.removeLast()
            right = rightStack.children.isEmpty ? nil : .stacking(rightStack)
            appendToSide(moved, side: &left, align: .right)
        case .up, .down:
            return nil
        }
        return moved
    }

    mutating func updateCenterFraction(proposedWidth: CGFloat, screenWidth: CGFloat) {
        centerWidthFraction = Self.clampedCenterFraction(
            proposedWidth: proposedWidth, screenWidth: screenWidth)
    }
```

### 3. Add sizing and helper methods

```swift
    // MARK: - Sizing

    mutating func recomputeSizes(width: CGFloat, height: CGFloat, updateSideWindowWidths: Bool = true) {
        // Move logic from ScrollingPositionService.recomputeSizes verbatim
        // Including setSideSizes and setSizes as private helpers
    }

    static func clampedCenterFraction(proposedWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {
        let minW = (screenWidth * Config.scrollCenterMinWidthFraction).rounded()
        let maxW = (screenWidth * Config.scrollCenterMaxWidthFraction).rounded()
        return min(maxW, max(minW, proposedWidth)) / screenWidth
    }

    // MARK: - Private

    private mutating func appendToSide(_ window: WindowSlot, side: inout Slot?, align: StackingAlign) {
        switch side {
        case nil:
            side = .stacking(StackingSlot(id: UUID(), parentId: id,
                                           size: .zero, children: [window], align: align))
        case .stacking(var s):
            s.children.append(window)
            side = .stacking(s)
        default: break
        }
    }

    private mutating func setSideSizes(_ slot: inout Slot, slotWidth: CGFloat, windowWidth: CGFloat?, height: CGFloat) { ... }
    private mutating func setSizes(_ slot: inout Slot, width: CGFloat, height: CGFloat) { ... }
}
```

### 4. Move ScrollingSlotLocation

Create `Model/ScrollingRoot/ScrollingSlotLocation.swift` and move the enum from `ScrollingRootStore.swift`:

```swift
// Which slot a window occupies in a scrolling root.
enum ScrollingSlotLocation {
    case center
    case left(index: Int, count: Int)
    case right(index: Int, count: Int)
}
```

### 5. Simplify ScrollingRootStore

After moving all tree logic, each method becomes a thin wrapper:

```swift
func scrollRight(screen: NSScreen) -> WindowSlot? {
    var logInfo: (hash: UInt, rootID: UUID)? = nil
    let result: WindowSlot? = store.queue.sync(flags: .barrier) {
        guard let id = visibleScrollingRootID(),
              case .scrolling(var root) = store.roots[id] else { return nil }
        let area = screenTilingArea(screen)
        guard let newCenter = root.scrollRight(screenArea: area) else { return nil }
        root.recomputeSizes(width: area.width, height: area.height, updateSideWindowWidths: false)
        store.roots[id] = .scrolling(root)
        logInfo = (hash: newCenter.windowHash, rootID: id)
        return newCenter
    }
    if let info = logInfo {
        WindowLister.logWindowEvent(action: "scrolled right", windowHash: info.hash, rootID: info.rootID)
    }
    return result
}
```

The store retains:
- Thread-safe store access (barrier blocks)
- Root creation/removal (store-level operations)
- Visibility lookups (`visibleScrollingRootID`)
- Logging
- `screenTilingArea` computation

### 6. Delete ScrollingPositionService

Its only method (`recomputeSizes`) is now on the struct. `clampedCenterFraction` is now a static method on `ScrollingRootSlot`.

---

## Key Technical Notes

- The `removeWindow` method returns a tuple `(removed: WindowSlot?, rootExhausted: Bool)` instead of the current pattern where the store calls `store.removeRoot(id:)` inline. The caller (`ScrollingRootStore.removeWindow`) checks `rootExhausted` and removes the root from the store. This keeps the struct method free of store dependencies.
- `addWindow` on the struct does NOT handle the window count or order assignment — that stays in `ScrollingRootStore` since it's store-level state. The store sets the order on the `WindowSlot` before calling `root.addWindow(key)`.
- `recomputeSizes` must be called after every mutation that changes the tree structure. In the current code this is done inline after each mutation. After the refactor, the store methods call `root.mutate()` then `root.recomputeSizes()`.
- The `updateSideWindowWidths: false` parameter pattern is preserved — it's needed when only the center changes (scroll, center resize) to avoid side windows jumping to new widths.
- `screenTilingArea` is a global helper function (not on the struct) — it reads `NSScreen` and `Config` to compute the usable area. The struct receives the computed area, not the screen.

---

## Verification

1. Build — no errors
2. Scroll a window → creates scrolling root with center window
3. Scroll more windows → added to left, center shifts
4. Scroll left/right navigation → windows cycle through center correctly
5. Focus a side window → auto-scrolls to center
6. Resize center window by dragging → side widths adjust
7. Close center window → side window promoted to center
8. Close side window → removed, layout adjusts
9. Unscroll all → all windows restored
10. Swap left/right → side windows swap correctly
11. Grep for `ScrollingPositionService` — no remaining references
