# Plan: 16_scrolling_focus_navigation — Scroll-aware left/right focus navigation

## Checklist

- [ ] Add `scrollLeft(screen:) -> WindowSlot?` and `scrollRight(screen:) -> WindowSlot?` to `ScrollingTileService`
- [ ] Create `ScrollingFocusService.swift` — orchestrates scroll + activation + reapply
- [ ] Update `FocusLeftHandler.swift` — call scrolling path when scrolling root is active
- [ ] Update `FocusRightHandler.swift` — call scrolling path when scrolling root is active

---

## Context / Problem

`FocusDirectionService.focus()` guards with `TileService.shared.snapshotVisibleRoot()`, so all four directional focus keys are already no-ops when a scrolling root is visible. Up/down should stay that way. Left/right, however, need to trigger a _scroll_ of the scrolling root instead of spatial focus.

---

## Behaviour spec

**Focus right** (viewport scrolls right — "go forward"):
1. Guard: right slot is `nil` → skip.
2. Extract the **first** child (`children[0]`) from the right slot's `StackingSlot`; if that leaves the stacking slot empty, set `right = nil`.
3. Move current center `WindowSlot` to the left slot: append it to the left `StackingSlot`'s children (create the `StackingSlot` with `align: .right` if left is `nil`).
4. The extracted window becomes the new `center`.

**Focus left** (viewport scrolls left — "go back"):
1. Guard: left slot is `nil` → skip.
2. Extract the **last** child (`children.last`) from the left slot's `StackingSlot`; if that empties it, set `left = nil`.
3. Move current center `WindowSlot` to the right slot: insert it at index `0` of the right `StackingSlot`'s children (create the `StackingSlot` with `align: .left` if right is `nil`).
4. The extracted window becomes the new `center`.

**Focus up / focus down**: already no-ops when a scrolling root is active (the tiling guard in `FocusDirectionService` returns early). No handler changes needed.

**Stack ordering rationale:**
- Left slot children: `append` on scroll-right, `removeLast` on scroll-left — the most-recently-seen window is always at the end (nearest to center conceptually).
- Right slot children: `insert(at: 0)` on scroll-left, `removeFirst` on scroll-right — same symmetry from the right side.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/ScrollingTileService.swift` | Modify — add `scrollLeft` and `scrollRight` mutation methods |
| `UnnamedWindowManager/System/ScrollingFocusService.swift` | **New file** — calls ScrollingTileService, activates new center window, triggers reapply |
| `UnnamedWindowManager/System/FocusLeftHandler.swift` | Modify — check for scrolling root, delegate to `ScrollingFocusService` |
| `UnnamedWindowManager/System/FocusRightHandler.swift` | Modify — check for scrolling root, delegate to `ScrollingFocusService` |

---

## Implementation Steps

### 1. Add scroll mutations to `ScrollingTileService`

Both methods return the `WindowSlot` that became the new center (so the caller can activate it), or `nil` if the operation was skipped.

```swift
/// Scrolls right: extracts the first child of the right slot into center,
/// moves old center to the left slot. Returns the new center window, or nil if right is empty.
func scrollRight(screen: NSScreen) -> WindowSlot? {
    store.queue.sync(flags: .barrier) {
        guard let id = visibleScrollingRootID(),
              case .scrolling(var root) = store.roots[id] else { return nil }
        guard case .stacking(var rightStack) = root.right else { return nil }

        let newCenterWin = rightStack.children.removeFirst()
        root.right = rightStack.children.isEmpty ? nil : .stacking(rightStack)

        if case .window(let oldCenter) = root.center {
            switch root.left {
            case nil:
                let s = StackingSlot(id: UUID(), parentId: id, width: 0, height: 0,
                                     children: [oldCenter], align: .right, order: .lifo)
                root.left = .stacking(s)
            case .stacking(var s):
                s.children.append(oldCenter)
                root.left = .stacking(s)
            default: break
            }
        }

        root.center = .window(newCenterWin)
        let og = Config.outerGaps
        let w = screen.visibleFrame.width  - og.left! - og.right!
        let h = screen.visibleFrame.height - og.top!  - og.bottom!
        position.recomputeSizes(&root, width: w, height: h)
        store.roots[id] = .scrolling(root)
        return newCenterWin
    }
}

/// Scrolls left: extracts the last child of the left slot into center,
/// moves old center to the right slot. Returns the new center window, or nil if left is empty.
func scrollLeft(screen: NSScreen) -> WindowSlot? {
    store.queue.sync(flags: .barrier) {
        guard let id = visibleScrollingRootID(),
              case .scrolling(var root) = store.roots[id] else { return nil }
        guard case .stacking(var leftStack) = root.left else { return nil }

        let newCenterWin = leftStack.children.removeLast()
        root.left = leftStack.children.isEmpty ? nil : .stacking(leftStack)

        if case .window(let oldCenter) = root.center {
            switch root.right {
            case nil:
                let s = StackingSlot(id: UUID(), parentId: id, width: 0, height: 0,
                                     children: [oldCenter], align: .left, order: .lifo)
                root.right = .stacking(s)
            case .stacking(var s):
                s.children.insert(oldCenter, at: 0)
                root.right = .stacking(s)
            default: break
            }
        }

        root.center = .window(newCenterWin)
        let og = Config.outerGaps
        let w = screen.visibleFrame.width  - og.left! - og.right!
        let h = screen.visibleFrame.height - og.top!  - og.bottom!
        position.recomputeSizes(&root, width: w, height: h)
        store.roots[id] = .scrolling(root)
        return newCenterWin
    }
}
```

### 2. Create `ScrollingFocusService`

Calls the mutation, activates the new center window (same pattern as `FocusDirectionService.activateWindow`), then triggers reapply.

```swift
// Handles left/right navigation for scrolling roots: rotates windows between zones.
struct ScrollingFocusService {

    static func scrollLeft() {
        guard let screen = NSScreen.main else { return }
        guard let newCenter = ScrollingTileService.shared.scrollLeft(screen: screen) else { return }
        activate(newCenter)
        ReapplyHandler.reapplyAll()
    }

    static func scrollRight() {
        guard let screen = NSScreen.main else { return }
        guard let newCenter = ScrollingTileService.shared.scrollRight(screen: screen) else { return }
        activate(newCenter)
        ReapplyHandler.reapplyAll()
    }

    private static func activate(_ key: WindowSlot) {
        guard let ax = ResizeObserver.shared.elements[key] else { return }
        NSRunningApplication(processIdentifier: key.pid)?.activate()
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
    }
}
```

### 3. Update `FocusLeftHandler` and `FocusRightHandler`

Check for a visible scrolling root first; delegate to `ScrollingFocusService` if found, otherwise fall through to the existing tiling path.

`FocusLeftHandler`:
```swift
static func focus() {
    if ScrollingTileService.shared.snapshotVisibleScrollingRoot() != nil {
        ScrollingFocusService.scrollLeft()
    } else {
        FocusDirectionService.focus(.left)
    }
}
```

`FocusRightHandler` is symmetric with `scrollRight`.

---

## Key Technical Notes

- `visibleScrollingRootID()` is `private` in `ScrollingTileService`; `snapshotVisibleScrollingRoot()` is the public guard used in the handlers.
- `scrollLeft`/`scrollRight` must be called inside a `.barrier` block because they read-modify-write `store.roots`. They already call `visibleScrollingRootID()` internally, which performs its own CGWindowList scan — that is acceptable since both happen within the same barrier block.
- When the right slot `StackingSlot` becomes empty after `removeFirst`, set `root.right = nil` (not an empty stacking slot) so `ScrollingPositionService` knows no side width is needed on the right.
- Same nil-collapse logic applies to left on `removeLast`.
- `StackingSlot` for the right slot is created with `align: .left` so windows extend off-screen to the right (matching the established convention).
- `recomputeSizes` must run after the mutation so `ScrollingLayoutService` has updated widths. The window widths for side slots are `centerWidth` (set by `setSideSizes`), not `sideWidth`.

---

## Verification

1. Press Scroll → window A in center. Press Scroll on window B → A in left, B in center.
2. Press focus-right → right slot empty → no change.
3. Press focus-left → A moves back to center, B goes to right slot (first child).
4. Press focus-right → B back to center, A back to left slot.
5. Add window C via Scroll → A in left, B also in left, C in center.
6. Press focus-left → B becomes center (last of left), C goes to right.
7. Press focus-left again → A becomes center, B goes to right slot at index 0.
8. Press focus-right → B returns to center, A stays in left.
9. Up/Down with scrolling root active → no-op (windows don't move).
10. Tile a window (non-scrolling root) → focus left/right use tiling spatial behaviour as before.
