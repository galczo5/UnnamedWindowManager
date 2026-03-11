# Plan: 14_stacking_slot — Overlapping Window Stack Slot

## Checklist

- [x] Add `StackingAlign` enum (`.left`, `.right`)
- [x] Add `StackingOrder` enum (`.lifo`, `.fifo`)
- [x] Add `StackingSlot` struct
- [x] Add `.stacking(StackingSlot)` case to `Slot` enum with all computed properties
- [x] Update `PositionService` to handle `.stacking` (set height = slot height, preserve per-window width)
- [x] Update `LayoutService` to handle `.stacking` (overlap all windows, apply AXRaise for z-order)
- [x] Update `SlotTreeQueryService` to `fatalError` on `.stacking` in all switch statements
- [x] Update `SlotTreeMutationService` to `fatalError` on `.stacking` in all switch statements

---

## Context / Problem

The existing slot types (`HorizontalSlot`, `VerticalSlot`) divide screen space among children — no two windows overlap. A `StackingSlot` is a new container type where all children occupy the same screen position and overlap each other, like a deck of cards. Alignment controls which edge they anchor to; order controls z-ordering (which window is on top).

---

## Behaviour Spec

- `children: [WindowSlot]` — direct window leaves only, no nested containers
- `height` — always equals the screen height (set by `PositionService` from the root's height)
- `width` — the width the parent grants via `fraction`, just like other slot types (not constrained)
- **Align `.left`** — all windows share the same `x = origin.x` (left edges coincide)
- **Align `.right`** — all windows right-align to `origin.x + slot.width` (each window's `x = origin.x + slot.width - window.width`)
- **Order `.lifo`** — last window in `children` is raised to the top (children raised first→last)
- **Order `.fifo`** — first window in `children` is raised to the top (children raised last→first)
- Z-ordering is applied via `AXRaise` on each window's `AXUIElement` in the appropriate sequence

---

## macOS Z-Order Note

`AXUIElementPerformAction(element, kAXRaiseAction)` raises a window within its owning application. For windows from different apps, the last-raised window from the most-recently-activated app ends up on top. To get a deterministic cross-app z-stack, iterate children in reverse-priority order so the highest-priority window is raised last and its owning app is activated last. This is best-effort; system restrictions may prevent perfect ordering across all apps.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Model/StackingAlign.swift` | **New file** — `StackingAlign` enum |
| `UnnamedWindowManager/Model/StackingOrder.swift` | **New file** — `StackingOrder` enum |
| `UnnamedWindowManager/Model/StackingSlot.swift` | **New file** — `StackingSlot` struct |
| `UnnamedWindowManager/Model/Slot.swift` | Modify — add `.stacking` case and computed properties |
| `UnnamedWindowManager/Services/PositionService.swift` | Modify — add `.stacking` branch |
| `UnnamedWindowManager/System/LayoutService.swift` | Modify — add `.stacking` branch with AXRaise |
| `UnnamedWindowManager/Services/SlotTreeQueryService.swift` | Modify — add `.stacking` to all switch statements |
| `UnnamedWindowManager/Services/SlotTreeMutationService.swift` | Modify — add `.stacking` to all switch statements |

---

## Implementation Steps

### 1. StackingAlign and StackingOrder enums

Two small files:

```swift
// StackingAlign.swift
enum StackingAlign {
    case left, right
}

// StackingOrder.swift
enum StackingOrder {
    case lifo, fifo
}
```

### 2. StackingSlot struct

Mirrors the shape of `HorizontalSlot`/`VerticalSlot` but holds `[WindowSlot]` directly instead of `[Slot]`.

```swift
// StackingSlot.swift
/// A container where all children overlap at the same position; alignment and z-order are configurable.
struct StackingSlot {
    var id: UUID
    var parentId: UUID
    var width: CGFloat
    var height: CGFloat
    var children: [WindowSlot]
    var align: StackingAlign
    var order: StackingOrder
    var fraction: CGFloat = 1.0
}
```

### 3. Update Slot enum

Add the new case and fill in all three computed properties (`id`, `parentId`, `width`, `height`, `fraction`).

```swift
indirect enum Slot {
    case window(WindowSlot)
    case horizontal(HorizontalSlot)
    case vertical(VerticalSlot)
    case stacking(StackingSlot)

    var id: UUID {
        switch self {
        // ... existing cases ...
        case .stacking(let s): return s.id
        }
    }

    var parentId: UUID {
        get {
            switch self {
            // ... existing ...
            case .stacking(let s): return s.parentId
            }
        }
        set {
            switch self {
            // ... existing ...
            case .stacking(var s): s.parentId = newValue; self = .stacking(s)
            }
        }
    }

    // width, height, fraction follow the same pattern
}
```

### 4. PositionService — stacking branch

All children get the slot's full height; their width is unchanged (preserved from whatever was assigned). The slot's own width and height are updated normally.

```swift
case .stacking(var s):
    s.width = width; s.height = height
    for i in s.children.indices {
        s.children[i].height = height
        // width is preserved per-window; do not override
    }
    slot = .stacking(s)
```

### 5. LayoutService — stacking branch

Position all children at the same y-origin. Apply alignment for x. Then raise windows via AX in priority order so the correct window ends up on top.

```swift
case .stacking(let s):
    // Determine raise sequence: raise lowest-priority first
    let raisedLast: [WindowSlot]
    switch s.order {
    case .lifo:  raisedLast = s.children            // last element raised last = on top
    case .fifo:  raisedLast = s.children.reversed() // first element raised last = on top
    }

    for w in raisedLast {
        guard let ax = elements[w] else { continue }
        let g = w.gaps ? Config.innerGap : 0
        let xOffset: CGFloat = s.align == .left
            ? 0
            : s.width - w.width
        var pos  = CGPoint(x: (origin.x + xOffset + g).rounded(),
                           y: (origin.y + g).rounded())
        var size = CGSize(width: (w.width - g * 2).rounded(),
                          height: (w.height - g * 2).rounded())
        if let posVal  = AXValueCreate(.cgPoint, &pos)  { AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, posVal) }
        if let sizeVal = AXValueCreate(.cgSize,  &size) { AXUIElementSetAttributeValue(ax, kAXSizeAttribute  as CFString, sizeVal) }
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
    }
```

### 6. SlotTreeQueryService — stacking branches

Every private switch must gain a `.stacking` arm that throws a fatal error. Stacking slots must never appear as intermediate nodes in the recursive tiling tree traversal — encountering one indicates a programming error.

```swift
case .stacking:
    fatalError("StackingSlot encountered in tiling tree traversal — stacking slots are not supported by SlotTreeQueryService")
```

Apply this to all private recursive helpers: `collectLeaves`, `findLeafSlot`, `maxLeafOrder`, `findParentOrientation`.

### 7. SlotTreeMutationService — stacking branches

Same approach: every switch arm that recurses into `Slot` children must throw a fatal error on `.stacking`.

```swift
case .stacking:
    fatalError("StackingSlot encountered in tiling tree mutation — stacking slots are not supported by SlotTreeMutationService")
```

Apply this to all recursive helpers: `removeFromTree`, `extractAndWrap`, `updateLeaf`, `flipParentOrientation`.

---

## Key Technical Notes

- `StackingSlot.children` is `[WindowSlot]`, not `[Slot]` — it is a terminal node; the slot tree services must never recurse into it
- `SlotTreeQueryService` and `SlotTreeMutationService` both `fatalError` on `.stacking` — these services are tiling-tree-only and stacking slots are managed separately
- `PositionService` must NOT divide height by fraction for stacking children — they all get the full `height`, not a share
- Z-raising is best-effort; windows from different processes may not respect the intended order if the app doesn't support `kAXRaiseAction`
- `fraction` on `StackingSlot` still participates in the parent's space distribution (so the slot can coexist with other siblings in a `TilingRootSlot` or `HorizontalSlot`)

---

## Verification

1. Create a `StackingSlot` with two windows, `align: .left`, `order: .lifo` → both windows are left-aligned at the same x, the second window is visually on top
2. Switch to `align: .right` → both windows right-align; right edges are flush with the slot's right boundary
3. Switch to `order: .fifo` → first window is visually on top
4. Add a third window → all three overlap; z-order follows FIFO/LIFO rules
5. Remove the top window → remaining two restack correctly
6. Place `StackingSlot` as a sibling of a `VerticalSlot` inside a horizontal root → both occupy their fractions without interference
7. Screen resize → stacking slot's height updates to full screen height, windows reposition correctly
