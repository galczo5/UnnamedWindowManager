# Plan: 13_mode_exclusivity — Tiled and Scrolled Modes Are Mutually Exclusive

## Checklist

- [ ] Add notification + early return for scroll shortcut when tiled
- [ ] Add notification + early return for scrollAll shortcut when tiled
- [ ] Add notification + early return for tile shortcut when scrolled
- [ ] Add notification + early return for tileAll shortcut when scrolled
- [ ] Disable "Tile" menu button when scrolled
- [ ] Disable "Tile all" menu button when scrolled
- [ ] Disable "Scroll" menu button when tiled
- [ ] Disable "Scroll all" menu button when tiled

---

## Context / Problem

Currently, tiling and scrolling can theoretically conflict on the same screen. The scroll handlers already have silent guards (`guard TileService.shared.snapshotVisibleRoot() == nil else { return }`), but they give no feedback. Tile handlers have no guard against an active scrolling root.

The goal is to make the two modes strictly exclusive per screen:
- If a tiling root is active, keyboard shortcuts for scroll/scroll-all show a notification and do nothing. Menu scroll actions are disabled.
- If a scrolling root is active, keyboard shortcuts for tile/tile-all show a notification and do nothing. Menu tile actions are disabled.

Untile/Unscroll actions are never blocked — those are always allowed.

---

## Behaviour Spec

| Mode active | Blocked shortcuts | Blocked menu items |
|-------------|-------------------|--------------------|
| Tiled | scroll, scrollAll | "Scroll", "Scroll all" |
| Scrolled | tile, tileAll | "Tile", "Tile all" |

Untile/Unscroll shortcuts and menu items are never disabled.

The notification title/body:
- Tiled → blocked scroll: `"Cannot scroll"` / `"Untile all windows first."`
- Scrolled → blocked tile: `"Cannot tile"` / `"Unscroll all windows first."`

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/KeybindingService.swift` | Modify — add mode guards with notifications in four shortcut closures |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — add `.disabled()` modifiers to four menu buttons |

---

## Implementation Steps

### 1. Guard keyboard shortcuts in `KeybindingService.swift`

The four shortcut closures that need changes are in `start()`, in the `candidates` array (lines 31–52). Replace them with guarded versions:

```swift
(Config.tileShortcut, "tile", {
    if ScrollingTileService.shared.snapshotVisibleScrollingRoot() != nil {
        NotificationService.shared.post(title: "Cannot tile", body: "Unscroll all windows first.")
        return
    }
    TileHandler.tileToggle()
}),
(Config.tileAllShortcut, "tileAll", {
    if ScrollingTileService.shared.snapshotVisibleScrollingRoot() != nil {
        NotificationService.shared.post(title: "Cannot tile", body: "Unscroll all windows first.")
        return
    }
    if TileService.shared.snapshotVisibleRoot() != nil {
        UntileHandler.untileAll()
    } else {
        OrganizeHandler.organize()
    }
}),
(Config.scrollShortcut, "scroll", {
    if TileService.shared.snapshotVisibleRoot() != nil {
        NotificationService.shared.post(title: "Cannot scroll", body: "Untile all windows first.")
        return
    }
    ScrollingRootHandler.scrollToggle()
}),
(Config.scrollAllShortcut, "scrollAll", {
    if TileService.shared.snapshotVisibleRoot() != nil {
        NotificationService.shared.post(title: "Cannot scroll", body: "Untile all windows first.")
        return
    }
    if ScrollingTileService.shared.snapshotVisibleScrollingRoot() != nil {
        UnscrollHandler.unscrollAll()
    } else {
        ScrollOrganizeHandler.organizeScrolling()
    }
}),
```

The `tileAll` shortcut currently shows "Untile all" when tiled, which is an un-tile action and must never be blocked — the guard only fires in the `else` path (`OrganizeHandler.organize()`). Because the `if` branch (untileAll) executes without entering the guard, the early return only blocks the organize (tile) direction.

Wait — actually the guard fires before the branch, so it blocks untileAll too when scrolled. That is wrong. We need the guard only to block *tiling*, not *untiling*.

Correct approach: for `tileAll`, only block the organize path, not the untile path:

```swift
(Config.tileAllShortcut, "tileAll", {
    if TileService.shared.snapshotVisibleRoot() != nil {
        UntileHandler.untileAll()
    } else if ScrollingTileService.shared.snapshotVisibleScrollingRoot() != nil {
        NotificationService.shared.post(title: "Cannot tile", body: "Unscroll all windows first.")
    } else {
        OrganizeHandler.organize()
    }
}),
```

Similarly for `scrollAll`, only block the organize-scrolling path, not the unscroll path:

```swift
(Config.scrollAllShortcut, "scrollAll", {
    if ScrollingTileService.shared.snapshotVisibleScrollingRoot() != nil {
        UnscrollHandler.unscrollAll()
    } else if TileService.shared.snapshotVisibleRoot() != nil {
        NotificationService.shared.post(title: "Cannot scroll", body: "Untile all windows first.")
    } else {
        ScrollOrganizeHandler.organizeScrolling()
    }
}),
```

For `tile` (tileToggle): if scrolled and frontmost is scrolled, toggling would unscroll — that must also not be blocked. So the guard needs to be in `tileToggle` itself only when not already tracked:

Actually the simplest correct split is: `scrollToggle` calls `UnscrollHandler.unscroll()` if already tracked (un-action, always allowed) or `scroll()` if not (blocked when tiled). Since `scrollToggle` branches on `isTracked`, the block should only fire on the `else` path. Do the guard inline in the shortcut closure:

```swift
(Config.scrollShortcut, "scroll", {
    // scrollToggle = unscroll (if tracked) or scroll (if not)
    // Only block the "scroll" direction, never the "unscroll" direction.
    let key: WindowSlot? = {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString,
              &focusedWindow) == .success else { return nil }
        return windowSlot(for: focusedWindow as! AXUIElement, pid: pid)
    }()
    let alreadyScrolled = key.map { ScrollingTileService.shared.isTracked($0) } ?? false
    if !alreadyScrolled && TileService.shared.snapshotVisibleRoot() != nil {
        NotificationService.shared.post(title: "Cannot scroll", body: "Untile all windows first.")
        return
    }
    ScrollingRootHandler.scrollToggle()
}),
```

This is getting complex. A simpler and cleaner approach: block based on the overall screen mode rather than per-window tracking, since tiled/scrolled are mutually exclusive per screen anyway:

- `scroll` shortcut: if `isTiled` (tiling root visible), block with notification; else call `scrollToggle`.
- `tileAll` shortcut: if `isScrolled` (scrolling root visible), block the organize path only.
- `tile` shortcut: if `isScrolled`, block the tile path only.
- `scrollAll` shortcut: if `isTiled`, block the organize-scroll path only.

Since `scrollToggle()` would unscroll if the frontmost is scrolled, and if scrolled root is visible (not tiling root), the `scroll` shortcut guard (`isTiled`) won't fire — it's safe.

Similarly, `tileToggle()` would untile if frontmost is tiled; if tiling root is visible, scrolled root isn't, so the `isScrolled` guard won't fire.

So the simple up-front guard works correctly:

```swift
(Config.tileShortcut, "tile", {
    if ScrollingTileService.shared.snapshotVisibleScrollingRoot() != nil {
        NotificationService.shared.post(title: "Cannot tile", body: "Unscroll all windows first.")
        return
    }
    TileHandler.tileToggle()
}),
(Config.tileAllShortcut, "tileAll", {
    if TileService.shared.snapshotVisibleRoot() != nil {
        UntileHandler.untileAll()
    } else if ScrollingTileService.shared.snapshotVisibleScrollingRoot() != nil {
        NotificationService.shared.post(title: "Cannot tile", body: "Unscroll all windows first.")
    } else {
        OrganizeHandler.organize()
    }
}),
(Config.scrollShortcut, "scroll", {
    if TileService.shared.snapshotVisibleRoot() != nil {
        NotificationService.shared.post(title: "Cannot scroll", body: "Untile all windows first.")
        return
    }
    ScrollingRootHandler.scrollToggle()
}),
(Config.scrollAllShortcut, "scrollAll", {
    if ScrollingTileService.shared.snapshotVisibleScrollingRoot() != nil {
        UnscrollHandler.unscrollAll()
    } else if TileService.shared.snapshotVisibleRoot() != nil {
        NotificationService.shared.post(title: "Cannot scroll", body: "Untile all windows first.")
    } else {
        ScrollOrganizeHandler.organizeScrolling()
    }
}),
```

The `tile` shortcut guard fires before `tileToggle()`. When scrolled root is active there is no tiling root, so `tileToggle()` would try to tile — correct to block. When tiling root is active, there is no scrolling root, so the guard doesn't fire and `tileToggle()` toggles tile/untile normally.

### 2. Disable menu buttons in `UnnamedWindowManagerApp.swift`

Add `.disabled()` to the four action-direction buttons (not the un-action buttons). Unscroll/Untile buttons are never disabled.

```swift
// Tile section
if menuState.isFrontmostTiled {
    Button(menuLabel("Untile", Config.tileShortcut)) { UntileHandler.untile() }
} else {
    Button(menuLabel("Tile", Config.tileShortcut)) { TileHandler.tile() }
        .disabled(menuState.isScrolled)
}
if menuState.isTiled {
    Button(menuLabel("Untile all", Config.tileAllShortcut)) { UntileHandler.untileAll() }
} else {
    Button(menuLabel("Tile all", Config.tileAllShortcut)) { OrganizeHandler.organize() }
        .disabled(menuState.isScrolled)
}

// Scroll section
if menuState.isFrontmostScrolled {
    Button(menuLabel("Unscroll", Config.scrollShortcut)) { UnscrollHandler.unscroll() }
} else {
    Button(menuLabel("Scroll", Config.scrollShortcut)) { ScrollingRootHandler.scroll() }
        .disabled(menuState.isTiled)
}
if menuState.isScrolled {
    Button(menuLabel("Unscroll all", Config.scrollAllShortcut)) { UnscrollHandler.unscrollAll() }
} else {
    Button(menuLabel("Scroll all", Config.scrollAllShortcut)) { ScrollOrganizeHandler.organizeScrolling() }
        .disabled(menuState.isTiled)
}
```

---

## Key Technical Notes

- Tiled and scrolled modes are already mutually exclusive by design (scroll handlers guard against a visible tiling root), so the guards added here handle the only real gap: tile actions aren't guarded against a visible scrolling root.
- The `tileAll` and `scrollAll` shortcuts use a three-way branch to preserve the untile/unscroll direction while blocking only the tile/scroll direction.
- The `tile` shortcut early return is safe: when a scrolling root is visible, no tiling root exists, so `tileToggle()` would only tile — which we want to block. When tiling root is visible, no scrolling root exists, guard doesn't fire, toggle works normally.
- `menuState.isTiled` and `menuState.isScrolled` are refreshed on every menu open (`.onAppear`), workspace space change, tile-state-changed notification, and focus-changed notification — no additional refresh needed.

---

## Verification

1. Tile all windows → open menu → "Scroll" and "Scroll all" are greyed out / disabled.
2. Press scroll keyboard shortcut while tiled → notification appears: "Cannot scroll — Untile all windows first." — no scroll root is created.
3. Press scrollAll keyboard shortcut while tiled → same notification, no scroll root.
4. Untile all → scroll all windows → open menu → "Tile" and "Tile all" are greyed out / disabled.
5. Press tile keyboard shortcut while scrolled → notification appears: "Cannot tile — Unscroll all windows first." — no tile root is created.
6. Press tileAll keyboard shortcut while scrolled → same notification, no tile root.
7. Press tileAll keyboard shortcut while tiled → untiles all (not blocked).
8. Press scrollAll keyboard shortcut while scrolled → unscrolls all (not blocked).
9. Untile/unscroll buttons in menu are never greyed out regardless of mode.
