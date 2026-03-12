# Plan: 20_fix_focus_scroll_last_child — Fix focus scroll to use last-child semantics

## Checklist

- [x] In `scrollRight`: change `rightStack.children.removeFirst()` to `rightStack.children.removeLast()`
- [x] In `scrollLeft`: change `s.children.insert(oldCenter, at: 0)` to `s.children.append(oldCenter)`
- [x] Update doc comments on `scrollRight` and `scrollLeft` to reflect the new semantics

---

## Context / Problem

Plan 16 implemented `scrollLeft`/`scrollRight` in `ScrollingTileService` with a queue model for the right slot: windows were pushed with `insert(at: 0)` and popped with `removeFirst`. This gave the right slot FIFO-from-the-left semantics, matching a symmetric "cursor" model around the center.

Plan 18 then removed `StackingOrder` and established the invariant that **the last element of `children` is always the topmost window** (raised last in `ScrollingLayoutService.applySlot`). The right slot was not updated to match: its front-insert / front-remove pattern now means the old center window is buried at index 0 (bottom of the z-stack) instead of being the last child (top of the z-stack).

Two concrete bugs result:

1. **Focus right — new center extracted from wrong end of right slot**: `scrollRight` calls `rightStack.children.removeFirst()`. Under plan 18 semantics the topmost / most-recently-visited window is at `children.last`, so `removeLast()` is the correct extraction.
2. **Focus left — old center pushed to wrong end of right slot**: `scrollLeft` calls `s.children.insert(oldCenter, at: 0)`. After plan 18, `oldCenter` should be appended so it sits on top of the right stack.

The left slot already uses `append` (push) and `removeLast` (pop) correctly — giving it stack semantics. The right slot must mirror this.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/ScrollingTileService.swift` | Modify — fix `removeFirst` → `removeLast` in `scrollRight`; fix `insert(at: 0)` → `append` in `scrollLeft`; update doc comments |

---

## Implementation Steps

### 1. Fix `scrollRight` — extract last child of right slot

Change:
```swift
let newCenterWin = rightStack.children.removeFirst()
```
to:
```swift
let newCenterWin = rightStack.children.removeLast()
```

### 2. Fix `scrollLeft` — push old center as last child of right slot

In the existing `.stacking` branch, change:
```swift
s.children.insert(oldCenter, at: 0)
```
to:
```swift
s.children.append(oldCenter)
```

The `nil` branch (which creates a fresh single-element `StackingSlot`) requires no code change — a one-element array is self-consistent regardless of which end is "top".

### 3. Update doc comments

Update the method doc comments on `scrollRight` and `scrollLeft` to reflect that the right slot uses `append`/`removeLast` (stack semantics, last = topmost), not `insert(at:0)`/`removeFirst`.

---

## Key Technical Notes

- After plan 18, `ScrollingLayoutService.applySlot` raises `s.children` in order — the last element is raised last and therefore sits on top. Both left and right slots must use `append` on push and `removeLast` on pop to keep the most-recently-visited window on top.
- Plan 16's original rationale for `insert(at: 0)` / `removeFirst` was a symmetric cursor model where the right slot was a "forward" queue. That symmetry was invalidated by plan 18's z-order invariant — both sides must now use last = topmost stack semantics.
- No changes are needed outside `ScrollingTileService.swift`.

---

## Verification

1. Snap two windows into a scrolling root: A in center, B snapped → B becomes center, A goes to left slot.
2. Press focus-right (scroll right): no right slot exists → nothing happens (expected).
3. Press focus-left: B moves to right slot; A becomes center.
4. Press focus-right: A moves to left slot; B becomes center (extracted via `removeLast` — B was appended, so it's the last child).
5. With three windows A (left), B (center), C in right slot: press focus-left → B appended to right slot (B is last child, on top of C). A becomes center.
6. Press focus-right → A appended to left. B becomes center (last child of right slot, on top of C).
7. Confirm visual z-order: in any stacking slot the most-recently-visited window is always visually on top of older windows.
