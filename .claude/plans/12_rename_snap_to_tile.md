# Plan: 12_rename_snap_to_tile — Rename Snap/Unsnap to Tile/Untile

## Checklist

- [x] Rename menu labels: Snap → Tile, Unsnap → Untile, Snap all → Tile all, Unsnap all → Untile all
- [x] Rename config YAML keys: `snap` → `tile`, `snapAll` → `tileAll` in ConfigData.swift
- [x] Rename Config.swift properties: `snapShortcut` → `tileShortcut`, `snapAllShortcut` → `tileAllShortcut`
- [x] Rename SnapHandler.swift → TileHandler.swift (type + methods)
- [x] Rename UnsnapHandler.swift → UntileHandler.swift (type + methods)
- [x] Rename SnapService.swift → TileService.swift (type + methods)
- [x] Rename AutoSnapObserver.swift → AutoTileObserver.swift (type + internal references)
- [x] Update MenuState: `isSnapped` → `isTiled`, `isFrontmostSnapped` → `isFrontmostTiled`
- [x] Rename notification name `snapStateChanged` → `tileStateChanged`
- [x] Rename Slot.swift properties: `preSnapOrigin` → `preTileOrigin`, `preSnapSize` → `preTileSize`
- [x] Update all call sites across the codebase

---

## Context / Problem

The app uses "Snap" / "Unsnap" terminology throughout code, config, and the menu bar UI. The goal is to align with tiling window manager conventions by renaming these actions to "Tile" / "Untile" everywhere — user-facing labels, YAML config keys, and internal Swift symbols.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — menu labels + MenuState property names + notification name |
| `UnnamedWindowManager/Config.swift` | Modify — rename `snapShortcut` → `tileShortcut`, `snapAllShortcut` → `tileAllShortcut` |
| `UnnamedWindowManager/ConfigData.swift` | Modify — rename `ShortcutsConfig` fields `snap` → `tile`, `snapAll` → `tileAll` |
| `UnnamedWindowManager/System/SnapHandler.swift` | **Rename to** `TileHandler.swift` — rename type + methods |
| `UnnamedWindowManager/System/UnsnapHandler.swift` | **Rename to** `UntileHandler.swift` — rename type + methods |
| `UnnamedWindowManager/Services/SnapService.swift` | **Rename to** `TileService.swift` — rename type + methods |
| `UnnamedWindowManager/Observation/AutoSnapObserver.swift` | **Rename to** `AutoTileObserver.swift` — rename type + internal refs |
| `UnnamedWindowManager/Model/Slot.swift` | Modify — rename `preSnapOrigin` → `preTileOrigin`, `preSnapSize` → `preTileSize` |
| `UnnamedWindowManager/Services/KeybindingService.swift` | Modify — update references to renamed config properties and handlers |
| `UnnamedWindowManager/System/OrganizeHandler.swift` | Modify — update any calls to snap-named symbols |
| `UnnamedWindowManager/Observation/PostResizeValidator.swift` | Modify — update any snap-named references |
| `UnnamedWindowManager/Observation/ResizeObserver.swift` | Modify — update any snap-named references |
| `UnnamedWindowManager/Observation/WindowVisibilityManager.swift` | Modify — update any snap-named comments/references |

---

## Implementation Steps

### 1. Menu labels and MenuState (UnnamedWindowManagerApp.swift)

Update the `MenuBarExtra` button labels and the `MenuState` class properties:

```swift
// MenuState: rename properties
var isTiled: Bool = false         // was isSnapped
var isFrontmostTiled: Bool = false // was isFrontmostSnapped

// MenuBarExtra buttons: rename labels
Button(menuLabel("Untile", Config.tileShortcut)) { UntileHandler.untile() }
Button(menuLabel("Tile", Config.tileShortcut)) { TileHandler.tile() }
Button(menuLabel("Untile all", Config.tileAllShortcut)) { UntileHandler.untileAll() }
Button(menuLabel("Tile all", Config.tileAllShortcut)) { OrganizeHandler.organize() }

// Notification name
Notification.Name("tileStateChanged")  // was snapStateChanged
```

### 2. Config YAML keys (ConfigData.swift)

```swift
struct ShortcutsConfig: Codable {
    var tileAll: String?   // was snapAll, YAML key: tileAll
    var tile: String?      // was snap,    YAML key: tile
    // defaults:
    // tile: "cmd+;"
    // tileAll: "cmd+'"
}
```

Update the `Default` static value and any `CodingKeys` if present to keep backward compatibility or simply replace.

### 3. Config.swift properties

```swift
var tileShortcut: String { ... }     // was snapShortcut
var tileAllShortcut: String { ... }  // was snapAllShortcut
```

### 4. Rename handler files and types

**TileHandler.swift** (was SnapHandler.swift):
- Type: `SnapHandler` → `TileHandler`
- Methods: `snap()` → `tile()`, `snapToggle()` → `tileToggle()`, `snapLeft()` → `tileLeft()`

**UntileHandler.swift** (was UnsnapHandler.swift):
- Type: `UnsnapHandler` → `UntileHandler`
- Methods: `unsnap()` → `untile()`, `unsnapAll()` → `untileAll()`

### 5. Rename service file and type

**TileService.swift** (was SnapService.swift):
- Type: `SnapService` → `TileService`
- All public methods keep their functional names; only the type name changes here unless method names also reference snap (e.g. `snapshotVisibleRoot()` can stay since it's a distinct concept, or rename to `snapshotVisibleRoot()` — leave as-is unless confusing).

### 6. Rename observer file and type

**AutoTileObserver.swift** (was AutoSnapObserver.swift):
- Type: `AutoSnapObserver` → `AutoTileObserver`
- Internal method: `snapFocusedWindow(pid:screenWasEmpty:)` → `tileFocusedWindow(pid:screenWasEmpty:)`
- Update call to `TileHandler.tileLeft()` (was `SnapHandler.snapLeft()`)

### 7. Slot.swift property rename

```swift
var preTileOrigin: CGPoint?   // was preSnapOrigin
var preTileSize: CGSize?      // was preSnapSize
```

Update all read/write sites in TileHandler, UntileHandler, and any other files.

### 8. Update all remaining call sites

After renaming files and types, do a global search for any remaining `snap`/`unsnap`/`Snap`/`Unsnap` symbols and update them. Key locations:
- `KeybindingService.swift` — `Config.tileShortcut`, `Config.tileAllShortcut`, `TileHandler.tileToggle()`, `UntileHandler.untileAll()`
- `OrganizeHandler.swift` — any internal snap references
- `PostResizeValidator.swift` — any snap references
- `ResizeObserver.swift` — any snap references
- `WindowVisibilityManager.swift` — update the comment referencing unsnap

---

## Key Technical Notes

- File renames in Xcode must be done via "Rename" in the file inspector or directly on disk + project file update; since we edit files directly, rename the `.swift` file and update the Xcode `.xcodeproj` group reference (or just rename and let Xcode resolve).
- The YAML config key rename (`snap` → `tile`, `snapAll` → `tileAll`) is a breaking change for existing user config files — no backward-compat shim needed per project style.
- Notification name `snapStateChanged` is internal only; no external subscribers outside the app bundle.
- `SnapService.snapshotVisibleRoot()` — the word "snapshot" is unrelated to snap; leave method name unchanged.
- After renaming `preSnapOrigin`/`preSnapSize`, search all files for these identifiers to ensure no missed references.

---

## Verification

1. Build the project — no compile errors.
2. Launch the app → menu bar icon appears.
3. Focus a window → menu shows "Tile" (not "Snap") with shortcut hint.
4. Press the tile shortcut (cmd+;) → window tiles into layout → menu now shows "Untile".
5. Press untile shortcut again → window untiles → menu shows "Tile".
6. Open menu → "Tile all" option visible when no windows are tiled.
7. Press tile-all shortcut (cmd+') → all windows tile → menu shows "Untile all".
8. Press untile-all shortcut → all windows untile.
9. Check that config YAML with old `snap`/`snapAll` keys no longer loads custom shortcuts (expected breakage).
10. Update config YAML to use `tile`/`tileAll` keys → shortcuts load correctly.
