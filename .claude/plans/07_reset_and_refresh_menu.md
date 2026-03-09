# Plan: 17_reset_and_refresh_menu — Add Reset Layout and Refresh Menu Items

## Checklist

- [x] Add `resetLayoutShortcut` and `refreshShortcut` to `ShortcutsConfig` in `ConfigData.swift`
- [x] Add `Config.resetLayoutShortcut` and `Config.refreshShortcut` static accessors in `Config.swift`
- [x] Add YAML entries with comments in `ConfigLoader.swift`
- [x] Add `Reset layout` button to menu with `menuLabel`
- [x] Add `Refresh` button to menu with `menuLabel`

---

## Context / Problem

Two new menu actions are needed:

1. **Reset layout** — equivalent to "start over": unsnap all windows, then re-organize them. Gives a clean, fresh tiling layout without manually clicking two buttons.

2. **Refresh** — reapply the current slot layout's computed position and size to every managed window. Useful when windows have drifted from their slots (e.g. after a screen resolution change, system sleep, or a window that refused a resize earlier).

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/ConfigData.swift` | Modify — add `resetLayout` and `refresh` to `ShortcutsConfig` with empty-string defaults |
| `UnnamedWindowManager/Config.swift` | Modify — add `resetLayoutShortcut` and `refreshShortcut` static accessors |
| `UnnamedWindowManager/ConfigLoader.swift` | Modify — add YAML lines with comments for the two new shortcuts |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — add two new `Button` entries using `menuLabel` |

---

## Implementation Steps

### 1. Add shortcuts to `ConfigData.swift`

Add two new optional `String` fields to `ShortcutsConfig`, defaulting to `""` (disabled):

```swift
var resetLayout: String?
var refresh: String?
```

In `ConfigData.defaults`, set both to `""`:

```swift
shortcuts: ShortcutsConfig(..., resetLayout: "", refresh: "")
```

### 2. Add accessors to `Config.swift`

Follow the same force-unwrap pattern as existing shortcuts:

```swift
static var resetLayoutShortcut: String { shared.s.shortcuts!.resetLayout! }
static var refreshShortcut: String     { shared.s.shortcuts!.refresh! }
```

### 3. Add YAML entries to `ConfigLoader.swift`

Insert after the `flipOrientation` line, following the same comment style:

```yaml
# Global keyboard shortcut for Reset Layout. Empty string disables.
resetLayout: ""
# Global keyboard shortcut for Refresh. Empty string disables.
refresh: ""
```

### 4. Add `Reset layout` button to the menu

Calls `UnsnapHandler.unsnapAll()` followed by `OrganizeHandler.organize()` inline. Place after the existing `Organize` button and before the first `Divider()`. Uses `menuLabel` like all other buttons:

```swift
Button(menuLabel("Reset layout", Config.resetLayoutShortcut)) {
    UnsnapHandler.unsnapAll()
    OrganizeHandler.organize()
}
```

`OrganizeHandler.organize()` already calls `ReapplyHandler.reapplyAll()` and `PostResizeValidator.checkAndFixRefusals` with the 0.3 s delay, so no extra calls are needed.

### 5. Add `Refresh` button to the menu

Place immediately after `Reset layout`:

```swift
Button(menuLabel("Refresh", Config.refreshShortcut)) {
    ReapplyHandler.reapplyAll()
}
```

---

## Key Technical Notes

- `UnsnapHandler.unsnapAll()` posts `snapStateChanged` but does **not** call `ReapplyHandler.reapplyAll()` — that's fine because `OrganizeHandler.organize()` rebuilds everything from scratch immediately after.
- `OrganizeHandler.organize()` includes the 0.3 s `PostResizeValidator.checkAndFixRefusals` call — no need to duplicate it.
- `ReapplyHandler.reapplyAll()` prunes off-screen windows before applying layout, so `Refresh` is safe to call even if the window set has changed since last organize.
- `KeybindingService` reads shortcuts from `Config` at startup and on `restart()` — new shortcuts are automatically picked up when the config is reloaded, same as existing shortcuts.
- Both shortcut fields must be added to `ConfigData.defaults` or the force-unwrap in `Config` will crash on first launch with a missing YAML key.

---

## Verification

1. With no managed windows: click **Reset layout** → windows organize into slots → menu shows `[organized]`.
2. While organized: drag a window away from its slot → click **Refresh** → window snaps back to its slot dimensions.
3. Click **Reset layout** while already organized → layout resets cleanly (no duplicate windows, no stale slots).
4. With no managed windows: click **Refresh** → no crash, no visible change.
