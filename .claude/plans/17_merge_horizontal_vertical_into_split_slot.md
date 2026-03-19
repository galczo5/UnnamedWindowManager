# Plan: 17_merge_horizontal_vertical_into_split_slot — Unify HorizontalSlot/VerticalSlot into SplitSlot and consolidate size fields

## Checklist

### Part A: Merge HorizontalSlot + VerticalSlot → SplitSlot

- [x] Create `SplitSlot.swift` with orientation field and `size: CGSize`
- [x] Update `Slot` enum: replace `.horizontal`/`.vertical` with `.split`
- [x] Update `Slot` computed properties (id, parentId, size, fraction)
- [x] Add `Orientation.flipped` computed property
- [x] Update `SlotTreeQueryService.swift` — merge duplicate H/V cases
- [x] Update `SlotTreeMutationService.swift` — merge cases, simplify flip logic
- [x] Update `SlotTreeInsertService.swift` — merge cases, simplify construction
- [x] Update `PositionService.swift` — merge H/V cases
- [x] Update `ResizeService.swift` — merge H/V cases
- [x] Update `LayoutService.swift` — merge H/V cases
- [x] Update `DirectionalNeighborService.swift` — merge H/V cases
- [x] Update `WindowLister.swift` — merge H/V cases
- [x] Delete `HorizontalSlot.swift` and `VerticalSlot.swift`

### Part B: Replace `width`/`height` with `size: CGSize` across all slot types

- [x] Update `WindowSlot` — replace `width`/`height` with `size: CGSize`
- [x] Update `StackingSlot` — replace `width`/`height` with `size: CGSize`
- [x] Update `TilingRootSlot` — replace `width`/`height` with `size: CGSize`
- [x] Update `ScrollingRootSlot` — replace `width`/`height` with `size: CGSize`
- [x] Update `Slot` enum computed properties — expose `size` instead of `width`/`height`
- [x] Update `PositionService.swift` — use `.size.width`/`.size.height`
- [x] Update `ScrollingPositionService.swift` — use `.size`
- [x] Update `ResizeService.swift` — use `.size`
- [x] Update `LayoutService.swift` — use `.size`
- [x] Update `ScrollingLayoutService.swift` — use `.size`
- [x] Update `DirectionalNeighborService.swift` — use `.size`
- [x] Update `PostResizeValidator.swift` — use `.size`
- [x] Update `SlotTreeInsertService.swift` — use `.size`
- [x] Update `WindowLister.swift` — use `.size`
- [x] Build and verify

---

## Context / Problem

`HorizontalSlot` and `VerticalSlot` are **structurally identical** — same fields, same semantics, only the name differs. The actual layout direction is already determined by `Orientation` at the `TilingRootSlot` level or by convention in service code. Having two types means:

- **Every switch on `Slot`** has two cases that do exactly the same thing (`.horizontal` and `.vertical`). This applies to the `Slot` enum itself (5 computed properties × 2 = 10 redundant arms) and **10+ service files** with their own switches.
- **Flip-orientation** in `SlotTreeMutationService.flipParentOrientation` reconstructs a brand-new struct of the opposite type, field-by-field — instead of toggling a single property.
- **New features** touching the slot tree must add the same code twice.
- `gaps` is stored on both container types but **never read** on containers — only on `WindowSlot`.

Additionally, all slot types store size as two separate `width: CGFloat` + `height: CGFloat` fields, while `WindowSlot` already uses `CGSize` and `CGPoint` for its pre-tile state (`preTileOrigin: CGPoint?`, `preTileSize: CGSize?`). This is inconsistent — CoreGraphics types should be used uniformly.

This plan merges H/V into `SplitSlot` and consolidates size fields to `size: CGSize` across all slot types.

---

## Files to create / modify

| File | Action |
|------|--------|
| `Model/SplitSlot.swift` | **New file** — replaces HorizontalSlot + VerticalSlot, uses `size: CGSize` |
| `Model/HorizontalSlot.swift` | **Delete** |
| `Model/VerticalSlot.swift` | **Delete** |
| `Model/Slot.swift` | Modify — replace `.horizontal`/`.vertical` with `.split`; expose `size` instead of `width`/`height` |
| `Model/WindowSlot.swift` | Modify — `width`/`height` → `size: CGSize` |
| `Model/StackingSlot.swift` | Modify — `width`/`height` → `size: CGSize` |
| `Model/TilingRootSlot.swift` | Modify — `width`/`height` → `size: CGSize` |
| `Model/ScrollingRootSlot.swift` | Modify — `width`/`height` → `size: CGSize` |
| `Model/Orientation.swift` | Modify — add `flipped` computed property |
| `Services/SlotTreeQueryService.swift` | Modify — merge H/V cases |
| `Services/SlotTreeMutationService.swift` | Modify — merge cases, simplify flip, use `.size` |
| `Services/SlotTreeInsertService.swift` | Modify — merge cases, simplify construction, use `.size` |
| `Services/PositionService.swift` | Modify — merge H/V cases, use `.size` |
| `Services/ResizeService.swift` | Modify — merge H/V cases, use `.size` |
| `Services/ScrollingPositionService.swift` | Modify — use `.size` |
| `System/LayoutService.swift` | Modify — merge H/V cases, use `.size` |
| `System/ScrollingLayoutService.swift` | Modify — use `.size` |
| `Services/DirectionalNeighborService.swift` | Modify — merge H/V cases, use `.size` |
| `Observation/PostResizeValidator.swift` | Modify — use `.size` |
| `System/WindowLister.swift` | Modify — merge H/V cases, use `.size` |

---

## Implementation Steps

### 1. Create `SplitSlot`

New file `Model/SplitSlot.swift`:

```swift
import Foundation

/// A container slot whose children are split along an orientation — horizontal (left→right) or vertical (top→bottom).
struct SplitSlot {
    var id: UUID
    var parentId: UUID
    var size: CGSize
    var orientation: Orientation
    var children: [Slot]
    /// Share of the parent container's space in the split direction. Siblings sum to 1.0.
    var fraction: CGFloat = 1.0
}
```

Note: `gaps` is intentionally omitted — it was stored on HorizontalSlot/VerticalSlot but never read on containers. Only `WindowSlot.gaps` is used (in `LayoutService`, `DirectionalNeighborService`, `ResizeService`, `ScrollingLayoutService`, `PostResizeValidator`).

### 2. Add `Orientation.flipped`

```swift
enum Orientation {
    case horizontal
    case vertical

    var flipped: Orientation {
        self == .horizontal ? .vertical : .horizontal
    }
}
```

### 3. Replace `width`/`height` with `size: CGSize` on all slot types

Update each model struct. For example, `WindowSlot`:

```swift
// Before
var width: CGFloat
var height: CGFloat

// After
var size: CGSize
```

Apply the same change to `StackingSlot`, `TilingRootSlot`, and `ScrollingRootSlot`.

### 4. Update `Slot` enum

Replace the two cases with one and update computed properties:

```swift
indirect enum Slot {
    case window(WindowSlot)
    case split(SplitSlot)
    case stacking(StackingSlot)
}
```

Replace separate `width`/`height` getters with a single `size` property:

```swift
var size: CGSize {
    switch self {
    case .window(let w):   return w.size
    case .split(let s):    return s.size
    case .stacking(let s): return s.size
    }
}
```

All computed properties shrink from 4 arms to 3.

### 5. Update service files — mechanical merge of H/V cases

In every service file, adjacent `.horizontal(let h)` / `.vertical(let v)` case arms that do the same thing collapse into a single `.split(let s)` arm. The bound variable changes from `h`/`v` to `s` and `.children` / `.id` / etc. stay the same since the fields are identical.

Where code previously distinguished direction (e.g. PositionService checking `root.orientation == .horizontal`), it now reads `s.orientation` instead.

### 6. Update all `width`/`height` access sites to use `size`

Mechanical replacement across service files. The patterns:

```swift
// Read access
w.width  → w.size.width
w.height → w.size.height

// Write access
w.width = x; w.height = y  → w.size = CGSize(width: x, height: y)
// or when only one dimension changes:
w.size.width = x
```

Affected files: `PositionService`, `ScrollingPositionService`, `ResizeService`, `LayoutService`, `ScrollingLayoutService`, `DirectionalNeighborService`, `PostResizeValidator`, `SlotTreeInsertService`, `WindowLister`.

### 7. Simplify `flipParentOrientation` in SlotTreeMutationService

The current implementation reconstructs a brand-new struct of the opposite type field-by-field. After the merge, flipping becomes toggling one field:

```swift
case .split(var s):
    if s.children.contains(where: {
        if case .window(let w) = $0 { return w == key }; return false
    }) {
        s.orientation = s.orientation.flipped
        slot = .split(s)
        return true
    }
    for i in s.children.indices {
        if flipParentOrientation(of: key, in: &s.children[i]) {
            slot = .split(s); return true
        }
    }
    return false
```

### 8. Simplify container construction in SlotTreeInsertService and SlotTreeMutationService

Where code previously chose which type to construct via a ternary:

```swift
let container = isHorizontal
    ? .horizontal(HorizontalSlot(id: ..., ...))
    : .vertical(VerticalSlot(id: ..., ...))
```

It becomes:

```swift
let container = Slot.split(SplitSlot(id: ..., orientation: orientation, ...))
```

### 9. Delete `HorizontalSlot.swift` and `VerticalSlot.swift`

Remove from the project and Xcode build target.

---

## Key Technical Notes

- `TilingRootSlot` already has its own `orientation` field — it is the root and is not a `Slot` case. Its structure stays the same (only `width`/`height` → `size`).
- `StackingSlot.children` is `[WindowSlot]` not `[Slot]` — it doesn't participate in the H/V merge and remains a separate case.
- `gaps` on containers is dead code. Searching all reads of `.gaps` confirms they only ever read `WindowSlot.gaps`. The field was copied during flip/swap but never consumed for layout. Safe to drop.
- The `Orientation.flipped` property centralizes the toggle logic that currently appears inline in SlotTreeMutationService and SlotTreeInsertService.
- Do both parts (A and B) together rather than sequentially — since both touch the same files, combining them avoids editing each file twice.
- `Slot.width` and `Slot.height` are read-only computed getters. After the change, the enum exposes a single `size: CGSize` getter. Call sites that read `child.width` become `child.size.width`.

---

## Verification

1. Build the project — zero compiler errors
2. Tile two windows side by side → they split horizontally as before
3. Tile a third window below one of them → vertical split appears
4. Use flip-orientation shortcut → split direction toggles correctly
5. Resize a split boundary → fractions update, windows reposition
6. Use swap-direction shortcuts → windows swap correctly
7. Close a tiled window → tree collapses, remaining windows reposition
8. Scrolling mode still works (unaffected by this change)
