# Plan: 18_stacking_slot_remove_order — Remove StackingOrder, Last Child Always on Top

## Checklist

- [x] Delete `StackingOrder.swift`
- [x] Remove `order` property from `StackingSlot`
- [x] Replace `.stacking` branch in `LayoutService.swift` with `fatalError`
- [x] Simplify raise sequence in `ScrollingLayoutService.swift`
- [x] Remove `order:` label from `StackingSlot` constructors in `ScrollingTileService.swift`
- [x] Remove `order=` from log line in `WindowLister.swift`

---

## Context / Problem

`StackingSlot` currently has an `order: StackingOrder` property (`.lifo` or `.fifo`) that controls whether the first or last child is raised to the top. The layout services branch on this value to build a raise sequence. All existing call sites pass `.lifo`, meaning last-in is always displayed on top.

The goal is to simplify: always treat the last element of `children` as the topmost window. When adding a child to a stacking slot, append it (`children.append`). When removing from a stacking slot, remove the last child (`children.removeLast`). This removes the `StackingOrder` type entirely and eliminates the conditional in both layout services.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Model/StackingOrder.swift` | **Delete** — enum no longer needed |
| `UnnamedWindowManager/Model/StackingSlot.swift` | Modify — remove `var order: StackingOrder` |
| `UnnamedWindowManager/System/LayoutService.swift` | Modify — replace `.stacking` branch with `fatalError` (dead code) |
| `UnnamedWindowManager/System/ScrollingLayoutService.swift` | Modify — simplify raise sequence to `s.children` |
| `UnnamedWindowManager/Services/ScrollingTileService.swift` | Modify — remove `order:` from 3 `StackingSlot(...)` initialisers |
| `UnnamedWindowManager/System/WindowLister.swift` | Modify — remove `order=\(s.order)` from log |

---

## Implementation Steps

### 1. Delete StackingOrder.swift

Remove the file entirely. The `StackingOrder` enum has no other usages.

### 2. Remove `order` from StackingSlot

```swift
struct StackingSlot {
    var id: UUID
    var parentId: UUID
    var width: CGFloat
    var height: CGFloat
    var children: [WindowSlot]
    var align: StackingAlign
    var fraction: CGFloat = 1.0
}
```

### 3. Replace `.stacking` branch in LayoutService with fatalError

`TilingRootSlot` trees never contain stacking slots — `SlotTreeMutationService` and `SlotTreeInsertService` both `fatalError` on `.stacking`. The branch in `LayoutService` is dead code. Replace it to match the invariant enforced elsewhere:

```swift
case .stacking:
    fatalError("StackingSlot encountered in tiling layout — stacking slots are only supported in scrolling roots")
```

### 4. Simplify raise sequence in ScrollingLayoutService

The raise sequence conditional is now gone. Replace:
```swift
let raiseSequence: [WindowSlot] = s.order == .lifo ? s.children : s.children.reversed()
for w in raiseSequence {
```
with:
```swift
for w in s.children {
```

### 5. Remove `order:` from StackingSlot initialisers in ScrollingTileService

Three call sites pass `order: .lifo` — remove that label/value from each.

### 6. Clean up WindowLister log

Remove `order=\(s.order)` from the stacking slot log line.

---

## Key Technical Notes

- `s.children` is already in insertion order; the last element is always the most recently added, so raising in `s.children` order means the last child is raised last (highest z-order). No reversed() needed.
- `scrollLeft` already calls `leftStack.children.removeLast()` to pop the most recent window — consistent with last = topmost semantics.
- `scrollRight` calls `rightStack.children.removeFirst()` — the right stack stores windows in the order they'll be visited when scrolling right, so the front is the next center. This is unrelated to z-order and stays unchanged.
- Stacking slots only exist in scrolling roots (created by `ScrollingTileService`). Tiling roots (`TilingRootSlot`) never contain them — `SlotTreeMutationService` and `SlotTreeInsertService` enforce this with `fatalError`. The `.stacking` branch in `LayoutService` therefore never executes and is replaced with `fatalError` to make the invariant explicit and symmetric.

---

## Verification

1. Build the project — should compile with no errors.
2. Snap two windows into a scrolling root → the second window (last added) is displayed on top.
3. Scroll left/right → the correct window becomes center, stacking slots update correctly.
