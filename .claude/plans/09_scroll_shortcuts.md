# Plan: 28_scroll_shortcuts — Keyboard Shortcuts for Scroll and Scroll All

## Checklist

- [x] Add `scroll` and `scrollAll` fields to `ShortcutsConfig` in `ConfigData.swift`
- [x] Update `defaults` in `ConfigData.swift` with `cmd+[` and `cmd+]`
- [x] Update `missingKeys` in `ConfigData.swift` to include both new fields
- [x] Update `mergedWithDefaults()` in `ConfigData.swift` to merge both new fields
- [x] Add `scrollShortcut` and `scrollAllShortcut` accessors to `Config.swift`
- [x] Register both shortcuts in `KeybindingService.swift` candidates list
- [x] Update Scroll / Scroll all / Unscroll / Unscroll all buttons in `UnnamedWindowManagerApp.swift` to use `menuLabel()`
- [x] Add `scrollToggle()` to `ScrollingRootHandler` (mirrors `TileHandler.tileToggle()`)
- [x] Update `scroll` keybinding to use `scrollToggle()`
- [x] Update `scrollAll` keybinding to toggle inline (mirrors `tileAll`)

---

## Context / Problem

The Scroll and Scroll all menu actions have no keyboard shortcuts. All other primary actions (Tile, Tile all, Flip Orientation, Focus directions) are wired to configurable shortcuts via `ShortcutsConfig`. Scroll/Scroll all are bare `Button(...)` calls with no shortcut hint and no keybinding registration.

Goal: add `scroll` and `scrollAll` to `ShortcutsConfig`, default them to `cmd+[` and `cmd+]`, register them in `KeybindingService`, and surface the shortcut hint in the menu label.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/ConfigData.swift` | Modify — add fields, defaults, missingKeys, mergedWithDefaults |
| `UnnamedWindowManager/Config.swift` | Modify — add two static accessors |
| `UnnamedWindowManager/Services/KeybindingService.swift` | Modify — add two candidates |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — use `menuLabel()` for Scroll buttons |

---

## Implementation Steps

### 1. Add fields to `ShortcutsConfig` in `ConfigData.swift`

Add two new optional fields to the struct:

```swift
struct ShortcutsConfig: Codable {
    // ... existing fields ...
    var scroll: String?
    var scrollAll: String?
}
```

Update the `defaults` static property to include them:

```swift
shortcuts: ShortcutsConfig(
    tileAll: "cmd+'", tile: "cmd+;", resetLayout: "", refresh: "",
    flipOrientation: "", focusLeft: "ctrl+opt+left", focusRight: "ctrl+opt+right",
    focusUp: "ctrl+opt+up", focusDown: "ctrl+opt+down",
    scroll: "cmd+[", scrollAll: "cmd+]"
),
```

Add checks in `missingKeys`:

```swift
check(s?.shortcuts?.scroll,    "config.shortcuts.scroll")
check(s?.shortcuts?.scrollAll, "config.shortcuts.scrollAll")
```

Add merge lines in `mergedWithDefaults()`:

```swift
shortcuts: ShortcutsConfig(
    // ... existing merge lines ...
    scroll:    s?.shortcuts?.scroll    ?? d.shortcuts!.scroll,
    scrollAll: s?.shortcuts?.scrollAll ?? d.shortcuts!.scrollAll
),
```

### 2. Add accessors to `Config.swift`

```swift
static var scrollShortcut: String    { shared.s.shortcuts!.scroll! }
static var scrollAllShortcut: String { shared.s.shortcuts!.scrollAll! }
```

### 3. Register in `KeybindingService.swift`

Add to the `candidates` array in `start()`:

```swift
(Config.scrollShortcut,    "scroll",    { ScrollingRootHandler.scroll() }),
(Config.scrollAllShortcut, "scrollAll", { ScrollOrganizeHandler.organizeScrolling() }),
```

The toggle logic for Scroll mirrors the menu's `isFrontmostScrolled` check, but since the shortcut fires without menu context, `ScrollingRootHandler.scroll()` already handles both creating and extending the scrolling root. `ScrollOrganizeHandler.organizeScrolling()` is already idempotent.

### 4. Update menu buttons in `UnnamedWindowManagerApp.swift`

Replace the four bare `Button(...)` calls with `menuLabel()`-wrapped versions:

```swift
if menuState.isFrontmostScrolled {
    Button(menuLabel("Unscroll", Config.scrollShortcut)) { UnscrollHandler.unscroll() }
} else {
    Button(menuLabel("Scroll", Config.scrollShortcut)) { ScrollingRootHandler.scroll() }
}
if menuState.isScrolled {
    Button("Unscroll all") { UnscrollHandler.unscrollAll() }
} else {
    Button(menuLabel("Scroll all", Config.scrollAllShortcut)) { ScrollOrganizeHandler.organizeScrolling() }
}
```

Note: "Unscroll" and "Unscroll all" don't have configurable shortcuts so they stay as bare labels.

---

## Key Technical Notes

- `cmd+[` and `cmd+]` use literal bracket characters as the key component; `KeybindingService.parse()` will match them via `nsEvent.charactersIgnoringModifiers`.
- The duplicate detection in `KeybindingService.start()` will catch any user-configured conflict with these new defaults automatically.
- `ScrollingRootHandler.scroll()` is already a no-op when a tiling root is active, so no guard is needed in the keybinding action.
- The `menuLabel()` helper already handles empty shortcut strings gracefully (returns just the base label), so if a user clears these shortcuts in config they degrade cleanly.

---

## Verification

1. Build and launch the app.
2. Open the menu — "Scroll" should show "(⌘[)" and "Scroll all" should show "(⌘])".
3. Press `cmd+[` — the focused window should be added to the scrolling root.
4. Press `cmd+]` — all visible windows should be organized into the scrolling root.
5. Set `scroll: "cmd+'"` in config (same as tileAll) and reload — a "Shortcut conflict" notification should appear and all shortcuts should be disabled.
6. Clear the new shortcuts (`scroll: ""`) in config and reload — menu falls back to bare "Scroll" / "Scroll all" labels; no keybinding is registered for them.
