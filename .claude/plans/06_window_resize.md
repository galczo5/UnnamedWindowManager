# Plan: 06_window_resize — Propagate resize through slot tree

## Checklist

- [x] Add `fraction` property to WindowSlot, HorizontalSlot, VerticalSlot
- [x] Update Slot computed properties to expose `fraction`
- [x] Rewrite `PositionService.recomputeSizes` to use fractions
- [x] Add `ResizeService` with resize propagation logic
- [x] Add `SnapService.resize(key:newWidth:newHeight:screen:)` method
- [x] Rewrite `ResizeObserver+Reapply` resize handling to use ResizeService
- [x] Update `SnapService.snap` to assign equal fractions on insert
- [x] Update `SlotTreeService.removeLeaf` to redistribute fractions on remove

---

## Context / Problem

Currently all children within a container are sized equally (`width / n` or `height / n`). When a user resizes a window, the existing code calls `setWidth()` which updates only the leaf's stored width — but the next `recomputeSizes()` call overwrites it back to equal distribution, making the change ephemeral.

The goal is to support persistent, proportional resizing:
- Each slot stores a `fraction` (0.0–1.0) representing its share of the parent's available space in the split direction.
- When a user drags a window edge, the delta is applied to the resized slot's fraction and compensated by adjusting its sibling(s).
- If the resize implies the parent container should change size, propagate upward through the tree.
- The root slot always fills 100% of the screen — the root's children fractions always sum to 1.0.

---

## Resize propagation spec

When a window is resized to a new actual size:

1. **Determine the resize axis.** Compare old vs new width and height. The axis with the larger delta is the resize axis. If the slot's parent splits in that axis direction, the resize is "same-axis" and adjusts sibling fractions. If the parent splits in the perpendicular axis, the resize must propagate upward.

2. **Same-axis resize (common case).** The slot's parent is a container splitting in the resize direction (e.g., user widens a window inside a horizontal container). Compute the delta in pixels. Convert to fraction delta = `pixelDelta / parentSizeInAxis`. Adjust the resized slot's fraction by +delta. Find the adjacent sibling (prefer the next sibling; fall back to previous) and adjust its fraction by -delta. Clamp both fractions to `[minFraction, 1.0]` where `minFraction` prevents zero-size slots. No upward propagation needed — the container's total remains 1.0.

3. **Cross-axis resize.** The slot's parent splits perpendicular to the resize direction (e.g., user changes height of a window inside a horizontal container). The parent container itself needs to change size in that axis. Walk up to the grandparent and apply the delta there using the same-axis logic. Continue walking up if the grandparent also splits in the wrong axis.

4. **Root boundary.** The root's children fractions always sum to 1.0. Any resize that reaches the root adjusts the root's direct children fractions and stops — the root size is fixed to screen dimensions.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Model/Slot.swift` | Modify — add `fraction` to WindowSlot, HorizontalSlot, VerticalSlot; add computed accessor on Slot |
| `UnnamedWindowManager/Services/PositionService.swift` | Modify — rewrite `recomputeSizes` to use `fraction` instead of `1/n` |
| `UnnamedWindowManager/Services/ResizeService.swift` | **New file** — resize propagation logic |
| `UnnamedWindowManager/Services/SnapService.swift` | Modify — add `resize()` method, update `snap()` to set equal fractions, remove `setWidth()` |
| `UnnamedWindowManager/Services/SlotTreeService.swift` | Modify — redistribute fractions when a leaf is removed |
| `UnnamedWindowManager/Observation/ResizeObserver+Reapply.swift` | Modify — call `ResizeService` instead of `setWidth` |

---

## Implementation Steps

### 1. Add `fraction` property to all slot types

Add `var fraction: CGFloat = 1.0` to `WindowSlot`, `HorizontalSlot`, and `VerticalSlot`. Add a computed `fraction` property on the `Slot` enum (getter and setter, same pattern as `parentId`).

The fraction represents the slot's share of its parent's size in the parent's split direction. All siblings' fractions within a container must sum to 1.0.

```swift
// In WindowSlot:
var fraction: CGFloat = 1.0

// In Slot extension:
var fraction: CGFloat {
    get {
        switch self {
        case .window(let w):     return w.fraction
        case .horizontal(let h): return h.fraction
        case .vertical(let v):   return v.fraction
        }
    }
    set {
        switch self {
        case .window(var w):     w.fraction = newValue; self = .window(w)
        case .horizontal(var h): h.fraction = newValue; self = .horizontal(h)
        case .vertical(var v):   v.fraction = newValue; self = .vertical(v)
        }
    }
}
```

### 2. Rewrite `PositionService.recomputeSizes` to use fractions

Instead of dividing equally (`width / n`), multiply the parent's available space by each child's `fraction`:

```swift
func recomputeSizes(_ root: inout RootSlot, width: CGFloat, height: CGFloat) {
    root.width = width
    root.height = height
    guard !root.children.isEmpty else { return }
    for i in root.children.indices {
        let cw = root.orientation == .horizontal ? width * root.children[i].fraction : width
        let ch = root.orientation == .horizontal ? height : height * root.children[i].fraction
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
        for i in h.children.indices {
            recomputeSizes(&h.children[i],
                           width: width * h.children[i].fraction,
                           height: height)
        }
        slot = .horizontal(h)
    case .vertical(var v):
        v.width = width; v.height = height
        for i in v.children.indices {
            recomputeSizes(&v.children[i],
                           width: width,
                           height: height * v.children[i].fraction)
        }
        slot = .vertical(v)
    }
}
```

### 3. Update `SnapService.snap` to assign equal fractions

When inserting a new window, `extractAndWrap` creates a container with two children. Both children should get `fraction = 0.5`. When a leaf is appended directly to root's children, all root children fractions should be recalculated to `1.0 / n`.

In `extractAndWrap`, after creating the container, set both children's fractions to 0.5. The new container inherits the fraction of the slot it replaced (so the parent container's total stays at 1.0).

```swift
// In SlotTreeService.extractAndWrap, when creating the container:
var existing = slot;  existing.parentId = containerId
var wrapped  = newLeaf; wrapped.parentId = containerId
// Set equal fractions for the two children
existing.fraction = 0.5
wrapped.fraction = 0.5
// The container inherits the replaced slot's fraction
let containerFraction = slot.fraction
// ... create container with fraction = containerFraction
```

### 4. Create `ResizeService`

This service handles the core resize propagation logic. It takes the resized window's key, the actual new size from AX, and mutates the tree.

```swift
struct ResizeService {
    private let tree = SlotTreeService()

    /// Minimum fraction any slot can shrink to (prevents zero-size slots).
    private let minFraction: CGFloat = 0.05

    /// Apply a user resize to the tree. Finds the resized window,
    /// computes the delta, and adjusts sibling fractions.
    func applyResize(
        key: WindowSlot,
        actualSize: CGSize,
        root: inout RootSlot
    ) {
        // 1. Find the leaf and its current size
        guard let leaf = tree.findLeafSlot(key, in: root),
              case .window(let w) = leaf else { return }

        let dw = actualSize.width - w.width
        let dh = actualSize.height - w.height

        // 2. Determine primary resize axis by larger delta
        let resizeHorizontal = abs(dw) >= abs(dh)
        let delta = resizeHorizontal ? dw : dh

        guard abs(delta) > 1.0 else { return }

        // 3. Walk up from the leaf to find the right container
        //    and adjust fractions
        adjustFractions(
            forSlotId: w.id,
            delta: delta,
            horizontal: resizeHorizontal,
            root: &root
        )
    }
}
```

The key method `adjustFractions` walks from the target slot upward through the tree:
- If the parent container splits in the resize direction, adjust the slot's fraction and its adjacent sibling's fraction.
- If the parent splits perpendicular, walk up to the grandparent and try there.
- Stop at the root (root children fractions are adjusted, root size is immutable).

Since the tree uses `parentId` references but not parent pointers, the implementation will use a recursive descent approach: find the path from root to the target slot, then adjust the appropriate container in that path.

### 5. Update `SlotTreeService.removeLeaf` to redistribute fractions

When a leaf is removed from a container with >2 children, redistribute its fraction share equally among remaining siblings. When a container collapses (down to 1 child), the surviving child inherits the container's fraction.

The collapse case is already handled (child replaces container) — just ensure `child.fraction = container.fraction` is set. For the multi-child case, add redistribution after removing the child:

```swift
// After removing child from container with N remaining children:
let removedFraction = 1.0 - newChildren.map(\.fraction).reduce(0, +)
let bonus = removedFraction / CGFloat(newChildren.count)
for i in newChildren.indices {
    newChildren[i].fraction += bonus
}
```

### 6. Rewrite resize handling in `ResizeObserver+Reapply`

Replace the current `verifyWidthsAfterResize` approach with `ResizeService`:

```swift
// In the isResize branch of scheduleReapplyWhenMouseUp:
if isResize {
    guard let screen = NSScreen.main,
          let axElement = self.elements[key],
          let actualSize = readSize(of: axElement) else { return }

    let allWindows = self.allTrackedWindows()
    self.reapplying.formUnion(allWindows)
    SnapService.shared.resize(key: key, actualSize: actualSize, screen: screen)
    ReapplyHandler.reapplyAll()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.reapplying.subtract(allWindows)
    }
}
```

Remove `setWidth()` from SnapService and `verifyWidthsAfterResize` from the reapply extension — they are replaced by the new resize flow.

### 7. Add `SnapService.resize` method

```swift
func resize(key: WindowSlot, actualSize: CGSize, screen: NSScreen) {
    store.queue.sync(flags: .barrier) {
        resizeService.applyResize(key: key, actualSize: actualSize, root: &store.root)
        position.recomputeSizes(&store.root,
                                width: screen.visibleFrame.width - Config.gap * 2,
                                height: screen.visibleFrame.height - Config.gap * 2)
    }
}
```

---

## Key Technical Notes

- Fractions within any container must always sum to 1.0 — every mutation (snap, remove, resize) must maintain this invariant
- `recomputeSizes` now depends on fractions being set before it runs — calling it on a tree with default 1.0 fractions everywhere would give wrong results; this is fine because snap always sets fractions
- The `minFraction` clamp (0.05 = 5%) prevents windows from being resized to invisibility; this is the manager's constraint, separate from any app-imposed minimum size
- `verifyWidthsAfterResize` currently checks if apps rejected the assigned width — this logic should be preserved but simplified: after applying the resize and reapply, a single verification pass can detect app-rejected sizes and clamp the fraction accordingly
- `setWidth` is removed; `clampedWidth` in PositionService can also be removed unless needed elsewhere
- The resize delta must account for gaps — the actual window size from AX excludes gaps, but the slot's stored width/height includes them; the delta should be computed from slot widths (which include gaps) or the actual sizes should be gap-adjusted before comparison
- `extractAndWrap` creates containers with `fraction: 0` initially (since width/height are 0) — fractions must be set explicitly before `recomputeSizes` runs
- The tree path lookup (root → target) is O(depth) per resize — fine for typical tree depths of 3–6 levels

---

## Verification

1. Snap two windows → they tile 50/50 as before
2. Drag the edge between the two windows → the ratio changes; releasing preserves the new ratio
3. Snap a third window → it splits one of the halves into two equal parts; the other half is unchanged
4. Resize the third window → only its sibling adjusts; the other half of the screen is unaffected
5. Remove a window from a 3-window layout → remaining windows redistribute correctly, fractions sum to 1.0
6. Resize a window to its minimum app-enforced size → the slot fraction reflects the app's actual accepted size
7. Resize a window in a cross-axis direction (e.g., change height in a horizontal container) → the resize propagates to the parent and adjusts the correct sibling
8. Rapidly resize multiple windows → no crashes, no fraction drift (fractions always sum to 1.0 within each container)
