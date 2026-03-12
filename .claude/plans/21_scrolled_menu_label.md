# Plan: 21_scrolled_menu_label — Show [scrolled] label in menu bar when ScrollingRoot is visible

## Checklist

- [ ] Add `isScrolled` to `MenuState` and populate it in `refresh()`
- [ ] Update menu bar label to show `[scrolled]` when a scrolling root is visible

---

## Context / Problem

The menu bar icon already shows `[tiled]` when a `TilingRootSlot` is visible on screen. When a `ScrollingRootSlot` is the active layout, there is no visual indicator — the icon just shows the default rectangle image. The goal is to show `[scrolled]` in the same position when the visible root is a `ScrollingRootSlot`.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — add `isScrolled` to `MenuState`, update `refresh()`, update label HStack |

---

## Implementation Steps

### 1. Add `isScrolled` to `MenuState` and `refresh()`

Add the property and compute it alongside `isTiled`:

```swift
@Observable
final class MenuState {
    var parentOrientation: Orientation? = nil
    var isTiled: Bool = false
    var isFrontmostTiled: Bool = false
    var isScrolled: Bool = false

    func refresh() {
        parentOrientation = OrientFlipHandler.parentOrientation()
        isTiled = TileService.shared.snapshotVisibleRoot() != nil
        isScrolled = ScrollingTileService.shared.snapshotVisibleScrollingRoot() != nil
        isFrontmostTiled = { ... }()
    }
}
```

### 2. Update the menu bar label HStack

The existing label block (lines 100–107) uses a simple `if/else` on `isTiled`. Extend it to also handle `isScrolled`. Both roots can be visible simultaneously, so show both labels when needed:

```swift
} label: {
    HStack(spacing: 4) {
        if menuState.isTiled || menuState.isScrolled {
            if menuState.isTiled   { Text("[tiled]") }
            if menuState.isScrolled { Text("[scrolled]") }
        } else {
            Image(systemName: "rectangle.split.3x1.fill")
        }
    }
```

---

## Key Technical Notes

- `ScrollingTileService.shared.snapshotVisibleScrollingRoot()` already exists and returns `nil` when no scrolling root is on screen — safe to call directly.
- `isTiled` and `isScrolled` are independent: both can be true at the same time if a tiling root and a scrolling root are simultaneously visible (e.g., one space has both). The label handles this by showing both texts side by side.
- No new notifications are needed; the existing `tileStateChanged` and `windowFocusChanged` observers already trigger `menuState.refresh()`, and `ScrollingRootHandler` posts `tileStateChanged` after mutating the store.

---

## Verification

1. Open any window and press "Scroll" from the menu → label should change to `[scrolled]`.
2. Open a second window and tile it (not scrolled) → label should show `[tiled]` (tiling root visible, no scrolling root).
3. With a scrolling root active, switch to a Space with no managed windows → label should revert to the icon.
4. With both a tiling root and scrolling root visible on the same screen → label shows `[tiled] [scrolled]`.
