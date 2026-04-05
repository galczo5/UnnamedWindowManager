# Plan: 07_tiling_root_methods — Move tiling tree operations onto TilingRootSlot

## Checklist

- [ ] Create `Model/TilingRoot/` directory
- [ ] Move `TilingRootSlot.swift` into `Model/TilingRoot/`
- [ ] Add query methods: `isTracked`, `allLeaves`, `findLeaf`, `maxLeafOrder`, `findParentOrientation`
- [ ] Add mutation methods: `removeLeaf`, `extractAndWrap`, `updateLeaf`, `replaceLeafIdentity`, `flipParentOrientation`
- [ ] Add insert methods: `insertAdjacent`, `swap`
- [ ] Add sizing methods: `recomputeSizes`
- [ ] Add resize method: `applyResize`
- [ ] Create `Model/TilingRoot/TilingSlotRecursion.swift` for private recursive helpers
- [ ] Update `TilingEditService` to call root methods
- [ ] Update `TilingSnapService` to call root methods
- [ ] Delete `TilingTreeQueryService.swift`
- [ ] Delete `TilingTreeMutationService.swift`
- [ ] Delete `TilingTreeInsertService.swift`
- [ ] Delete `TilingPositionService.swift`
- [ ] Delete `TilingResizeService.swift`
- [ ] Update all external references to deleted services
- [ ] Verify build and all functionality

---

## Context / Problem

Currently, operations on `TilingRootSlot` are spread across 5 separate service structs:
- `TilingTreeQueryService` — read-only traversals (80 lines)
- `TilingTreeMutationService` — remove, update, flip, wrap (192 lines)
- `TilingTreeInsertService` — insert adjacent, swap (155 lines)
- `TilingPositionService` — recomputeSizes (39 lines)
- `TilingResizeService` — fraction adjustment on resize (137 lines)

These are all pure operations on the tree — they take `inout TilingRootSlot` and don't need external state. Having them as separate services makes the code hard to follow: to understand what you can do with a root, you need to check 5 different files.

After this refactor, all operations become `mutating` methods on `TilingRootSlot` itself:

```swift
// Before:
TilingTreeMutationService().removeLeaf(key, from: &root)
TilingTreeQueryService().allLeaves(in: root)
TilingPositionService().recomputeSizes(&root, width: w, height: h)

// After:
root.removeLeaf(key)
root.allLeaves()
root.recomputeSizes(width: w, height: h)
```

---

## Decomposition strategy

Per CLAUDE.md, extensions must not be used for decomposition. Instead:

- **`TilingRootSlot.swift`** contains the struct definition and all public method signatures with their implementations. The methods that need deep tree recursion delegate to `TilingSlotRecursion`.
- **`TilingSlotRecursion.swift`** contains a `struct TilingSlotRecursion` with static methods for recursive `Slot`-level operations (the private helpers from current services). This is a separate type, not an extension.

Both files live in `Model/TilingRoot/`.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Model/TilingRoot/` | **New directory** |
| `UnnamedWindowManager/Model/TilingRoot/TilingRootSlot.swift` | **Move + expand** — from `Model/TilingRootSlot.swift`, add all methods |
| `UnnamedWindowManager/Model/TilingRoot/TilingSlotRecursion.swift` | **New file** — recursive Slot-level helpers |
| `UnnamedWindowManager/Model/TilingRootSlot.swift` | **Delete** (moved) |
| `UnnamedWindowManager/Services/Tiling/TilingTreeQueryService.swift` | **Delete** |
| `UnnamedWindowManager/Services/Tiling/TilingTreeMutationService.swift` | **Delete** |
| `UnnamedWindowManager/Services/Tiling/TilingTreeInsertService.swift` | **Delete** |
| `UnnamedWindowManager/Services/Tiling/TilingPositionService.swift` | **Delete** |
| `UnnamedWindowManager/Services/Tiling/TilingResizeService.swift` | **Delete** |
| `UnnamedWindowManager/Services/Tiling/TilingEditService.swift` | Modify — call root methods |
| `UnnamedWindowManager/Services/Tiling/TilingSnapService.swift` | Modify — call root methods |
| `UnnamedWindowManager/Services/Tiling/TilingRootStore.swift` | Modify — call root methods |
| `UnnamedWindowManager/Services/Tiling/LayoutService.swift` | Modify — if it references deleted services |
| `UnnamedWindowManager/Services/ReapplyHandler.swift` | Modify — if it references deleted services |

---

## Implementation Steps

### 1. Create TilingSlotRecursion

Extract the recursive `Slot`-level helpers from the 5 services into one type. These are all pure functions on `Slot`:

```swift
// Recursive Slot-level helpers for TilingRootSlot tree operations.
// All methods are static and operate on inout Slot or Slot values.
struct TilingSlotRecursion {

    // From TilingTreeQueryService:
    static func findLeaf(_ key: WindowSlot, in slot: Slot) -> Slot? { ... }
    static func collectLeaves(in slot: Slot) -> [Slot] { ... }
    static func maxLeafOrder(in slot: Slot) -> Int { ... }
    static func findParentOrientation(of key: WindowSlot, in slot: Slot) -> Orientation? { ... }

    // From TilingTreeMutationService:
    static func removeFromTree(_ key: WindowSlot, slot: Slot) -> (slot: Slot?, found: Bool) { ... }
    static func extractAndWrap(_ slot: inout Slot, targetOrder: Int, newLeaf: Slot, orientation: Orientation) -> Bool { ... }
    static func updateLeaf(_ key: WindowSlot, in slot: inout Slot, update: (inout WindowSlot) -> Void) -> Bool { ... }
    static func flipParentOrientation(of key: WindowSlot, in slot: inout Slot) -> Bool { ... }
    static func redistributed(_ children: [Slot]) -> [Slot] { ... }

    // From TilingTreeInsertService:
    static func insertAdjacentInSlot(_ slot: inout Slot, targetKey: WindowSlot, dragged: Slot, needed: Orientation, draggedFirst: Bool) -> Bool { ... }
    static func replaceWindowInLeaf(_ slot: inout Slot, target: WindowSlot, with replacement: WindowSlot) -> Bool { ... }
    static func insertIntoChildren(_ children: inout [Slot], parentId: UUID, dragged: Slot, at targetIdx: Int, draggedFirst: Bool) { ... }
    static func makeWrapper(target: Slot, dragged: Slot, orientation: Orientation, draggedFirst: Bool) -> Slot { ... }

    // From TilingPositionService:
    static func recomputeSizes(_ slot: inout Slot, width: CGFloat, height: CGFloat) { ... }

    // From TilingResizeService:
    static func adjustFractions(_ children: inout [Slot], targetId: UUID, delta: CGFloat, horizontal: Bool, splitsHorizontal: Bool, sizeInAxis: CGFloat) { ... }
    // (plus applyFractionDelta helper)
}
```

The implementations are moved verbatim from the existing services — only the `self.` and struct context changes to `static`.

### 2. Add methods to TilingRootSlot

All methods delegate to `TilingSlotRecursion` for the recursive work:

```swift
struct TilingRootSlot {
    var id: UUID
    var size: CGSize
    var orientation: Orientation
    var children: [Slot]
    var gaps: Bool = true

    // MARK: - Query

    func isTracked(_ key: WindowSlot) -> Bool {
        findLeaf(key) != nil
    }

    func allLeaves() -> [Slot] {
        children.flatMap { TilingSlotRecursion.collectLeaves(in: $0) }
    }

    func findLeaf(_ key: WindowSlot) -> Slot? {
        children.compactMap { TilingSlotRecursion.findLeaf(key, in: $0) }.first
    }

    func maxLeafOrder() -> Int {
        children.map { TilingSlotRecursion.maxLeafOrder(in: $0) }.max() ?? 0
    }

    func parentOrientation(of key: WindowSlot) -> Orientation? {
        if children.contains(where: {
            if case .window(let w) = $0 { return w == key }; return false
        }) { return orientation }
        for child in children {
            if let o = TilingSlotRecursion.findParentOrientation(of: key, in: child) { return o }
        }
        return nil
    }

    // MARK: - Mutation

    @discardableResult
    mutating func removeLeaf(_ key: WindowSlot) -> Bool {
        var found = false
        let newChildren: [Slot] = children.compactMap {
            let (newSlot, wasFound) = TilingSlotRecursion.removeFromTree(key, slot: $0)
            if wasFound { found = true }
            return newSlot
        }
        if found { children = TilingSlotRecursion.redistributed(newChildren) }
        return found
    }

    mutating func extractAndWrap(targetOrder: Int, newLeaf: Slot, orientation: Orientation) {
        for i in children.indices {
            if TilingSlotRecursion.extractAndWrap(&children[i], targetOrder: targetOrder,
                                                   newLeaf: newLeaf, orientation: orientation) { return }
        }
    }

    @discardableResult
    mutating func updateLeaf(_ key: WindowSlot, update: (inout WindowSlot) -> Void) -> Bool {
        for i in children.indices {
            if TilingSlotRecursion.updateLeaf(key, in: &children[i], update: update) { return true }
        }
        return false
    }

    @discardableResult
    mutating func replaceLeafIdentity(oldKey: WindowSlot, newPid: pid_t, newHash: UInt) -> Bool {
        updateLeaf(oldKey) { w in
            var s = WindowSlot(pid: newPid, windowHash: newHash,
                               id: w.id, parentId: w.parentId,
                               order: w.order, size: w.size,
                               gaps: w.gaps, fraction: w.fraction,
                               preTileOrigin: w.preTileOrigin, preTileSize: w.preTileSize,
                               isTabbed: true)
            s.tabHashes = TabDetector.tabSiblingHashes(of: newHash, pid: newPid)
            w = s
        }
    }

    mutating func flipParentOrientation(of key: WindowSlot) {
        if children.contains(where: {
            if case .window(let w) = $0 { return w == key }; return false
        }) {
            orientation = orientation.flipped
            return
        }
        for i in children.indices {
            if TilingSlotRecursion.flipParentOrientation(of: key, in: &children[i]) { return }
        }
    }

    // MARK: - Insert

    mutating func insertAdjacent(_ dragged: Slot, adjacentTo targetKey: WindowSlot, zone: DropZone) {
        let needed: Orientation = (zone == .left || zone == .right) ? .horizontal : .vertical
        let draggedFirst = (zone == .left || zone == .top)

        if let idx = children.firstIndex(where: {
            if case .window(let w) = $0 { return w == targetKey }; return false
        }) {
            if orientation == needed {
                TilingSlotRecursion.insertIntoChildren(&children, parentId: id,
                                                        dragged: dragged, at: idx, draggedFirst: draggedFirst)
            } else {
                children[idx] = TilingSlotRecursion.makeWrapper(
                    target: children[idx], dragged: dragged,
                    orientation: needed, draggedFirst: draggedFirst)
            }
            return
        }
        for i in children.indices {
            if TilingSlotRecursion.insertAdjacentInSlot(&children[i], targetKey: targetKey,
                                                         dragged: dragged, needed: needed,
                                                         draggedFirst: draggedFirst) { return }
        }
    }

    mutating func swap(_ keyA: WindowSlot, _ keyB: WindowSlot) {
        guard findLeaf(keyA) != nil, findLeaf(keyB) != nil else { return }
        let sentinel = WindowSlot(pid: 0, windowHash: .max,
                                  id: UUID(), parentId: UUID(), order: -1, size: .zero)
        for i in children.indices { TilingSlotRecursion.replaceWindowInLeaf(&children[i], target: keyA, with: sentinel) }
        for i in children.indices { TilingSlotRecursion.replaceWindowInLeaf(&children[i], target: keyB, with: keyA) }
        for i in children.indices { TilingSlotRecursion.replaceWindowInLeaf(&children[i], target: sentinel, with: keyB) }
    }

    // MARK: - Sizing

    mutating func recomputeSizes(width: CGFloat, height: CGFloat) {
        size = CGSize(width: width, height: height)
        guard !children.isEmpty else { return }
        for i in children.indices {
            let cw = orientation == .horizontal ? (width * children[i].fraction).rounded() : width
            let ch = orientation == .horizontal ? height : (height * children[i].fraction).rounded()
            TilingSlotRecursion.recomputeSizes(&children[i], width: cw, height: ch)
        }
    }

    // MARK: - Resize

    mutating func applyResize(key: WindowSlot, actualSize: CGSize) {
        guard let leaf = findLeaf(key), case .window(let w) = leaf else { return }
        let gap = w.gaps ? Config.innerGap * 2 : 0
        let dw = (actualSize.width + gap) - w.size.width
        let dh = (actualSize.height + gap) - w.size.height
        let resizeH = abs(dw) >= abs(dh)
        let delta = resizeH ? dw : dh
        guard abs(delta) > 1.0 else { return }
        let splitsH = orientation == .horizontal
        let sizeInAxis = splitsH ? size.width : size.height
        TilingSlotRecursion.adjustFractions(&children, targetId: w.id, delta: delta,
                                             horizontal: resizeH, splitsHorizontal: splitsH,
                                             sizeInAxis: sizeInAxis)
    }
}
```

### 3. Update TilingEditService

Replace all service instantiations with direct root method calls:

```swift
// Before:
resizer.applyResize(key: key, actualSize: actualSize, root: &root)
position.recomputeSizes(&root, width: area.width, height: area.height)

// After:
root.applyResize(key: key, actualSize: actualSize)
root.recomputeSizes(width: area.width, height: area.height)
```

Remove the stored service instances (`treeQuery`, `treeMutation`, `treeInsert`, `position`, `resizer`).

The `resize`, `swap`, `recomputeVisibleRootSizes`, `flipParentOrientation`, `insertAdjacent` methods all simplify — they still handle store access and thread safety, but delegate tree work to `root.method()`.

### 4. Update TilingSnapService

Same transformation — remove service instances, call root methods:

```swift
// Before:
treeMutation.removeLeaf(key, from: &root)
treeQuery.maxLeafOrder(in: root)
treeMutation.extractAndWrap(in: &root, targetOrder: lastOrder, ...)
position.recomputeSizes(&root, width: area.width, height: area.height)

// After:
root.removeLeaf(key)
root.maxLeafOrder()
root.extractAndWrap(targetOrder: lastOrder, ...)
root.recomputeSizes(width: area.width, height: area.height)
```

### 5. Update TilingRootStore

Replace `TilingTreeQueryService()` calls:

```swift
// Before:
treeQuery.isTracked(key, in: root)
treeQuery.allLeaves(in: root)
treeQuery.findLeafSlot(key, in: root)
treeQuery.findParentOrientation(of: key, in: root)

// After:
root.isTracked(key)
root.allLeaves()
root.findLeaf(key)
root.parentOrientation(of: key)
```

### 6. Update other references

Grep for all usages of the deleted service types across the codebase:
- `TilingTreeQueryService` — used in `TilingRootStore`, `TilingEditService`, `TilingSnapService`, `SpaceChangeObserver` (or its replacement)
- `TilingTreeMutationService` — used in `TilingEditService`, `TilingSnapService`, `ResizeObserver` (or `WindowEventRouter`)
- `TilingPositionService` — used in `TilingEditService`, `TilingSnapService`, `ScrollingRootStore`
- `TilingResizeService` — used only in `TilingEditService`
- `TilingTreeInsertService` — used only in `TilingEditService`

### 7. Delete old service files

Remove the 5 files from the project.

---

## Key Technical Notes

- `TilingSlotRecursion` methods are `static` — they have no instance state. This matches the current pattern where services are stateless structs instantiated inline.
- The `minFraction` constant from `TilingResizeService` moves into `TilingSlotRecursion` as a private static constant.
- `replaceLeafIdentity` calls `TabDetector.tabSiblingHashes` — this is the only external dependency in the mutations. It stays as-is since `TabDetector` is a utility.
- The `fatalError` guards on `.stacking` cases in tiling operations are preserved — tiling trees never contain stacking slots.
- `TilingEditService` and `TilingSnapService` remain as services because they manage store access (barrier blocks, root lookups, root creation/removal). Only the tree operations move to the struct.
- After this stage, `TilingEditService` and `TilingSnapService` are noticeably simpler — each method becomes: lock → read root from store → call root.method() → write root back to store.

---

## Verification

1. Build — no errors
2. Tile windows → alternating horizontal/vertical splits
3. Resize a tiled window by dragging → neighboring window adjusts proportionally
4. Drag a window onto another → swap (center zone) or insert (edge zones)
5. Flip orientation → parent container toggles H/V
6. Untile a window → reflows, remaining windows fill gap
7. Close a tiled window → same reflow behavior
8. Tile all → all regular windows tile into one root
9. Untile all → all windows restored to pre-tile positions
10. Cross-root migration (move window via Mission Control) → consolidation works
11. Grep for `TilingTreeQueryService`, `TilingTreeMutationService`, `TilingTreeInsertService`, `TilingPositionService`, `TilingResizeService` — no remaining references
