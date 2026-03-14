# Plan: 26_fix_performance_regressions — Fix Layout Corruption from Plan 25

## Checklist

- [x] Fix `insertAdjacent` same-root duplicate window bug
- [x] Fix `lastApplied` cache preventing re-correction of refusing windows
- [x] Add duplicate-window guard to `insertAdjacent` and `swap`

---

## Context / Problem

After the performance improvements in plan 25 (commit a8cbcc7), window tiling positions and sizes broke. The screenshot shows extremely narrow windows squished to one side, and logs reveal tree corruption:

```
horizontal  size=690.0x472.0  children=2
  window  size=35.0x472.0  fraction=0.05  hash=72015    ← squeezed to 5%
  window  size=656.0x472.0  fraction=0.95  hash=71949   ← duplicate!
window  size=690.0x472.0  fraction=0.5  hash=71949      ← same window, different slot
```

Window hash 71949 appears in **two slots** — a duplicate. Window 72015 was squeezed to fraction=0.05 (35px) because the duplicate took its space. The window refused 35px and stayed at 73px, further distorting the layout.

**Root cause analysis identified three bugs:**

1. **`insertAdjacent` same-root duplicate** (pre-existing, exposed by plan 25): When dragging a window within the same root, `insertAdjacent` creates two independent copies of the root struct (`draggedRoot` and `targetRoot`). The dragged window is removed from `draggedRoot` but inserted into `targetRoot` (which still contains the original). Only `targetRoot` is stored back → the removal is lost → duplicate window in the tree.

2. **`lastApplied` cache prevents re-correction**: After `applyLayout` writes a window's position/size and caches it in `lastApplied`, if the window refuses (e.g., terminal with minimum width), subsequent `applyLayout` calls with the same tree state skip the write because the cache matches the intended value. `PostResizeValidator` mitigates this by adjusting fractions, but `lastApplied` should not cache values that weren't verified as applied.

3. **Plan 25 exposed bug #1**: The switch from AX-read-based drop-target detection (`findDropTarget` reading actual positions) to `computeFrames` (using slot-tree positions) changed which drop zones the cursor lands in. With computed frames that don't match actual window positions (e.g., after a refusal), the zone detection shifts from `.center` (swap) to directional zones (insert), triggering `insertAdjacent` in scenarios that previously triggered `swap`, exposing the same-root duplicate bug.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/TileService.swift` | Modify — fix `insertAdjacent` same-root logic, add `dragged == target` guard |
| `UnnamedWindowManager/System/LayoutService.swift` | Modify — clear `lastApplied` entry after AX write so refusal recovery works |
| `UnnamedWindowManager/System/ScrollingLayoutService.swift` | Modify — same `lastApplied` fix |

---

## Implementation Steps

### 1. Fix `insertAdjacent` same-root duplicate

The bug is at `TileService.swift:227-263`. When `draggedRootID == targetRootID`, both `draggedRoot` and `targetRoot` are independent `var` copies of the same root struct. The removal from `draggedRoot` (line 239) is never stored because the `if draggedRootID != targetRootID` guard (line 241) skips it, and `targetRoot` (which still has the original) overwrites it at line 261.

Fix: when same-root, remove from `targetRoot` instead of `draggedRoot`:

```swift
treeMutation.removeLeaf(dragged, from: &draggedRoot)
// Destroy source root only on cross-root drag that empties it.
if draggedRootID != targetRootID {
    if draggedRoot.children.isEmpty {
        store.roots.removeValue(forKey: draggedRootID)
        store.windowCounts.removeValue(forKey: draggedRootID)
    } else {
        store.roots[draggedRootID] = .tiling(draggedRoot)
    }
}
```

Becomes:

```swift
if draggedRootID == targetRootID {
    // Same root: remove from targetRoot so the removal and insertion
    // operate on the same struct, preventing duplicate window slots.
    treeMutation.removeLeaf(dragged, from: &targetRoot)
} else {
    treeMutation.removeLeaf(dragged, from: &draggedRoot)
    if draggedRoot.children.isEmpty {
        store.roots.removeValue(forKey: draggedRootID)
        store.windowCounts.removeValue(forKey: draggedRootID)
    } else {
        store.roots[draggedRootID] = .tiling(draggedRoot)
    }
}
```

### 2. Add duplicate-window guards

Add an early return to `insertAdjacent` when `dragged == target` (self-insert):

```swift
guard dragged != target else { return }
```

Add the same guard to `swap`:

```swift
guard keyA != keyB else { return }
```

### 3. Fix `lastApplied` cache for window refusal recovery

The `lastApplied` cache stores the intended position/size after issuing the AX write, but the window may refuse. On the next `applyLayout` with the same tree state, the cache match causes the write to be skipped entirely — the refusing window is never re-corrected.

Fix: remove the `lastApplied` entry immediately after writing. This way, every `applyLayout` call issues the AX write. The performance benefit of skipping unchanged writes still applies within a single `reapplyAll` burst because the 10ms debounce collapses multiple calls into one.

In `LayoutService.applyLayout(_:origin:elements:)`, remove line 120 (`lastApplied[w] = (pos, size)`) and in `ScrollingLayoutService.applySlot`, remove the equivalent lines. The cache entries are only set, never read in a way that provides value — the 10ms debounce already prevents redundant `reapplyAll` calls, and `PostResizeValidator` needs every write to fire.

Alternative (less aggressive): keep the cache but invalidate it at the start of each `reapplyAll` cycle by calling `clearCache()` at the top of `ReapplyHandler.reapplyAll()`. This preserves skip-unchanged within a single cycle while ensuring refusal recovery across cycles.

The alternative is preferred because it preserves the optimization for the common case (multiple windows, only one changed) while fixing refusal recovery.

```swift
// At the top of reapplyAll(), before applyLayout:
LayoutService.shared.clearCache()
ScrollingLayoutService.shared.clearCache()
```

---

## Key Technical Notes

- The `insertAdjacent` bug is pre-existing but was rarely triggered before plan 25 because the old `findDropTarget` (using live AX reads) produced more accurate zone detection. With `computeFrames`, zone boundaries shift when windows refuse sizes, triggering directional inserts instead of center swaps.
- `WindowSlot` comparison uses its `id: UUID` field. Two slots with the same `windowHash` but different `id` values (as created by `insertAdjacent`'s `newLeaf`) are considered different by `==`. This is why the duplicate persists — the tree has two distinct `WindowSlot` values pointing to the same physical window.
- The duplicate slot without an `elements` entry (the new leaf with fresh UUID) won't get AX writes applied (`guard let ax = elements[w] else { return }`), but it still consumes space in the tree layout, squeezing neighboring windows.
- Clearing `lastApplied` at the start of `reapplyAll()` means every debounced cycle writes all windows. With 6 windows, this is 12 AX calls per cycle — the same cost as before plan 25. The cache still helps during `ReapplyHandler.reapply(window:key:)` single-window restore and `PostResizeValidator`'s direct `applyLayout` call.

---

## Verification

1. Tile 3 windows horizontally → drag one window to the left edge of another (directional insert, not center swap) → all 3 windows should be correctly positioned, no duplicates in log
2. Tile 3 windows → drag within the same root repeatedly → `logSlotTree()` should never show duplicate hashes
3. Tile a terminal (has minimum width) alongside a browser → resize so the terminal hits its minimum → layout should still be correct after PostResizeValidator fires
4. Tile 6 windows → `reapplyAll` should still only trigger 1 CGWindowList call (OnScreenWindowCache still works)
5. Drag a window across 3 others → overlay updates correctly, zones detected properly
6. Switch Spaces and return → layout reapplies correctly
