# Plan: 22_scrolling_layout_skip_unchanged — Skip unnecessary AX calls on stacking windows during scroll

## Checklist

- [x] Remove `kAXRaiseAction` from stacking slot loop in `ScrollingLayoutService`
- [x] Pass `zonesChanged` flag from `ScrollingFocusService` through to `ScrollingLayoutService`
- [x] Skip position/size AX calls for stacking windows when their zone did not change

---

## Context / Problem

On every focus-left/right, `ScrollingLayoutService.applyLayout` fires AX position+size calls and `kAXRaiseAction` for **every window in every stacking slot**, even when those windows did not move.

Two sources of unnecessary screen activity:

1. **`kAXRaiseAction` on stacking children** — redundant. When a window moves from center → stacking slot it is already the topmost window (it was just the active center). Existing stacking children are already in correct z-order from prior scrolls. The new center is explicitly raised by `activateAfterLayout` anyway.

2. **Position/size AX calls for unchanged stacking windows** — stacking slot window geometry only changes when the number of occupied zones changes (e.g. left slot appears for the first time, shrinking center and making room for right). When the zone count is stable, all stacking-slot windows sit at exactly the same pixel rect as before.

---

## Zone change logic

`scrollLeft` and `scrollRight` in `ScrollingTileService` return a `WindowSlot?`. A zone count change can be detected by comparing the `left` / `right` presence before and after the mutation. Concretely, zones change when:

- A side slot transitions from `nil` → occupied, or occupied → `nil`.

The simplest signal: have the scrolling methods return a `Bool` indicating whether the zone configuration changed, alongside the new center window. Or compute it in `ScrollingFocusService` by snapshotting zone presence before and after calling `scrollLeft/Right`.

The cleanest approach without changing `ScrollingTileService`'s return type: snapshot the scrolling root before and after in `ScrollingFocusService`, compare `(left != nil, right != nil)` tuples, and pass `zonesChanged: Bool` to `applyLayout`.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/System/ScrollingLayoutService.swift` | Modify — remove `kAXRaiseAction`; add `zonesChanged` param to skip stacking AX calls |
| `UnnamedWindowManager/System/ScrollingFocusService.swift` | Modify — detect zone change and pass flag to `applyLayout` |
| `UnnamedWindowManager/System/LayoutService.swift` | Modify — forward `zonesChanged` to `ScrollingLayoutService` |

---

## Implementation Steps

### 1. Remove `kAXRaiseAction` from `ScrollingLayoutService`

Delete the single `AXUIElementPerformAction(ax, kAXRaiseAction as CFString)` line inside the `.stacking` case loop. No replacement needed.

### 2. Add `zonesChanged` parameter to `ScrollingLayoutService.applyLayout`

```swift
func applyLayout(root: ScrollingRootSlot, origin: CGPoint,
                 elements: [WindowSlot: AXUIElement],
                 zonesChanged: Bool) {
    ...
    if let left = root.left {
        if zonesChanged { applySlot(left, origin: ..., elements: elements) }
    }
    applySlot(root.center, origin: ..., elements: elements)  // always apply center
    if let right = root.right {
        if zonesChanged { applySlot(right, origin: ..., elements: elements) }
    }
}
```

### 3. Update `LayoutService.applyLayout` to forward the flag

`LayoutService.applyLayout(screen:)` is the call site. Add a `zonesChanged` parameter (defaulting to `true` for callers like `ReapplyHandler` that don't know):

```swift
func applyLayout(screen: NSScreen, zonesChanged: Bool = true) {
    ...
    if let root = ScrollingTileService.shared.snapshotVisibleScrollingRoot() {
        ScrollingLayoutService.shared.applyLayout(root: root, origin: origin,
                                                  elements: elements,
                                                  zonesChanged: zonesChanged)
    }
}
```

### 4. Detect zone change in `ScrollingFocusService` and pass it down

Snapshot the scrolling root before the mutation, then compare zone presence after:

```swift
static func scrollLeft() {
    guard let screen = NSScreen.main else { return }
    let before = ScrollingTileService.shared.snapshotVisibleScrollingRoot()
    let newCenter = ScrollingTileService.shared.scrollLeft(screen: screen)
    guard let newCenter else { return }
    let after = ScrollingTileService.shared.snapshotVisibleScrollingRoot()
    let zonesChanged = zoneSignature(before) != zoneSignature(after)
    LayoutService.shared.applyLayout(screen: screen, zonesChanged: zonesChanged)
    activateAfterLayout(newCenter)
}

private static func zoneSignature(_ root: ScrollingRootSlot?) -> (Bool, Bool) {
    (root?.left != nil, root?.right != nil)
}
```

`scrollRight` is symmetric.

---

## Key Technical Notes

- The center slot is **always** re-applied — it always has a new window after a scroll.
- Stacking slots are skipped only when `zonesChanged == false`; if a zone appears/disappears their width changes so they must be re-applied.
- `LayoutService.applyLayout(screen:)` is also called by `ReapplyHandler` and `ScrollOrganizeHandler` — the `zonesChanged: Bool = true` default ensures they continue to apply everything.
- `kAXRaiseAction` removal is safe regardless of `zonesChanged`; the two changes are independent.

---

## Verification

1. Scroll right with 3+ windows → only center redraws; stacking windows do not flicker.
2. Scroll until a new side zone appears → all windows reposition correctly (zonesChanged path).
3. Reapply layout (`Refresh` menu item) → all windows positioned correctly (default `zonesChanged: true`).
4. Scroll left/right rapidly → no unwanted z-order changes in stacking slots.
