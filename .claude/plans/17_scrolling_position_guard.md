# Plan: 17_scrolling_position_guard — Fix position/resize guard for ScrollingRoot windows

## Checklist

- [x] Add `leavesInVisibleScrollingRoot()` to `ScrollingTileService`
- [x] Remove early return for scrolling windows in `ResizeObserver.handle()`
- [x] Handle scrolling window move/resize in `ResizeObserver.scheduleReapplyWhenMouseUp()`
- [x] Include scrolling leaves in `ReapplyHandler.reapplyAll()` reapplying set
- [x] Include scrolling leaves in `PostResizeValidator.checkAndFixRefusals()`

---

## Context / Problem

When a user manually moves or resizes a window that belongs to a `ScrollingRootSlot` (either the center window or a window inside a `StackingSlot`), the window is **not** snapped back to its slot position/size. The position guard is completely broken for scrolling windows.

**Root cause**: `ResizeObserver.handle()` line 66 returns early for all scrolling-tracked windows:

```swift
if ScrollingTileService.shared.isTracked(key) { return }
```

This was likely added during initial scrolling development to prevent interference, but it now silently disables all position guarding for scrolling windows. Additionally, several downstream systems only query `TileService.shared.leavesInVisibleRoot()` (tiling-only), so even if the early return were removed, scrolling windows would still be missed by `ReapplyHandler.reapplyAll()` and `PostResizeValidator`.

**Goal**: After a user moves or resizes a scrolling window, it should snap back to its slot position and size — identical to how tiling windows behave today.

---

## Behaviour spec

- **Move**: When a scrolling window is dragged and released, it snaps back to its slot position. No swap/insert drop-zone behaviour (scrolling windows use scroll commands to reorder, not drag-drop).
- **Resize**: When a scrolling window is manually resized, it snaps back to its slot size. There is no fraction-based resize adjustment — scrolling slot sizes are computed from the 80/20 split, not from user-adjustable fractions.
- **Destroy**: Already works (line 71–81 in ResizeObserver calls `TileService.shared.removeAndReflow` which is not the scrolling path, but this plan does not address destroy — it's a separate concern).

---

## Files to create / modify

| File | Action |
|------|--------|
| `Services/ScrollingTileService.swift` | Modify — add `leavesInVisibleScrollingRoot()` |
| `Observation/ResizeObserver.swift` | Modify — replace early return with scrolling-specific handling |
| `System/ReapplyHandler.swift` | Modify — include scrolling leaves in reapplying set |
| `Observation/PostResizeValidator.swift` | Modify — include scrolling leaves in refusal checks |

---

## Implementation Steps

### 1. Add `leavesInVisibleScrollingRoot()` to `ScrollingTileService`

Multiple systems need to enumerate all `WindowSlot` leaves in the visible scrolling root. Add a method that collects them, mirroring `TileService.leavesInVisibleRoot()`.

```swift
func leavesInVisibleScrollingRoot() -> [Slot] {
    store.queue.sync {
        guard let id = visibleScrollingRootID(),
              case .scrolling(let root) = store.roots[id] else { return [] }
        var leaves: [Slot] = []
        func collect(_ slot: Slot) {
            switch slot {
            case .window:      leaves.append(slot)
            case .stacking(let s): leaves.append(contentsOf: s.children.map { .window($0) })
            default: break
            }
        }
        if let left  = root.left  { collect(left) }
        collect(root.center)
        if let right = root.right { collect(right) }
        return leaves
    }
}
```

### 2. Remove early return in `ResizeObserver.handle()`

Replace line 66:

```swift
if ScrollingTileService.shared.isTracked(key) { return }
```

with a guard that checks **either** tiling or scrolling tracking. Also skip drop-zone overlay for scrolling windows (they don't support swap/insert via drag).

The `handle()` method's existing guard on line 84 (`guard TileService.shared.isTracked(key)`) also needs updating to accept scrolling-tracked windows:

```swift
let isScrolling = ScrollingTileService.shared.isTracked(key)

// ...existing destroy handling...

guard TileService.shared.isTracked(key) || isScrolling else { return }
guard !reapplying.contains(key) else { return }

let isResize = notification == (kAXWindowResizedNotification as String)

// Drop-zone overlay only for tiling windows.
if !isScrolling && !isResize && NSEvent.pressedMouseButtons != 0 {
    // ...existing drop overlay logic...
}

scheduleReapplyWhenMouseUp(key: key, isResize: isResize, isScrolling: isScrolling)
```

### 3. Update `scheduleReapplyWhenMouseUp` for scrolling windows

Add an `isScrolling` parameter. For scrolling windows, both move and resize should just reapply the layout (no fraction adjustment, no swap/insert):

```swift
func scheduleReapplyWhenMouseUp(key: WindowSlot, isResize: Bool, isScrolling: Bool) {
    // ...existing cancellation and mouse-up polling...

    if isScrolling {
        // Scrolling windows: just snap back to slot position/size.
        self.reapplying.insert(key)
        if let screen = NSScreen.main {
            LayoutService.shared.applyLayout(screen: screen)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.reapplying.remove(key)
        }
        return
    }

    // ...existing tiling resize/move logic unchanged...
}
```

### 4. Include scrolling leaves in `ReapplyHandler.reapplyAll()`

Currently only tiling leaves are added to the `reapplying` set and passed to `PostResizeValidator`. Add scrolling leaves too:

```swift
let tilingLeaves = TileService.shared.leavesInVisibleRoot()
let scrollingLeaves = ScrollingTileService.shared.leavesInVisibleScrollingRoot()
let allLeaves = tilingLeaves + scrollingLeaves
let allWindows = Set(allLeaves.compactMap { leaf -> WindowSlot? in
    if case .window(let w) = leaf { return w }
    return nil
})
```

### 5. Include scrolling leaves in `PostResizeValidator.checkAndFixRefusals()`

Same pattern — collect leaves from both tiling and scrolling roots:

```swift
let tilingLeaves = TileService.shared.leavesInVisibleRoot()
let scrollingLeaves = ScrollingTileService.shared.leavesInVisibleScrollingRoot()
let leaves = tilingLeaves + scrollingLeaves
```

For scrolling windows that refuse to resize, `TileService.shared.resize()` won't find them in the tiling tree, so the resize call will be a no-op. This is fine — the refusal notification still gets posted, and the layout reapply will set the window to whatever size the slot tree dictates.

---

## Key Technical Notes

- Scrolling windows do **not** support drag-drop swap/insert — reordering is done via scroll commands only. The drop-zone overlay must be skipped for scrolling windows.
- Scrolling slot sizes are derived from the 80/20 split, not user-adjustable fractions. Resize for scrolling windows means "snap back", not "adjust fractions".
- `TileService.shared.resize()` is a no-op for scrolling windows (key not found in tiling tree), which is the correct behaviour.
- The `reapplying` set must include scrolling windows during `reapplyAll()` to prevent re-entrancy loops from AX notifications fired by the layout application itself.
- `LayoutService.applyLayout(screen:)` already applies both tiling and scrolling layouts (lines 18–23), so calling it is sufficient for scrolling reapply.

---

## Verification

1. Create a scrolling root with 3+ windows (center + left stack + right stack)
2. Drag the center window — it snaps back to center position on mouse-up
3. Drag a stacked (left/right) window — it snaps back to its stacking position on mouse-up
4. Resize the center window — it snaps back to its 80%-width slot size
5. Resize a stacked window — it snaps back to its slot size
6. Verify tiling windows still behave normally (move snaps back, resize adjusts fractions, swap/insert via drop zones still work)
7. Verify no infinite loop or rapid AX notification cycling (check logs for re-entrancy)
