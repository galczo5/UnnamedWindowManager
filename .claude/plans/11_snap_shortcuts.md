# Plan: 11_snap_shortcuts — Configurable shortcuts for Snap, Unsnap, Unsnap All, Flip Orientation

## Checklist

- [x] Add `snap`, `unsnap`, `unsnapAll`, `flipOrientation` fields to `ShortcutsConfig` in `ConfigData.swift`
- [x] Add defaults (all `""`) and wire into `missingKeys` and `mergedWithDefaults()`
- [x] Add accessors to `Config.swift`
- [x] Add new fields to YAML template in `ConfigLoader.swift`
- [x] Refactor `KeybindingService.swift` to support multiple bindings and skip empty strings
- [x] Update menu labels in `UnnamedWindowManagerApp.swift` to show shortcuts when non-empty

---

## Context / Problem

Snap, Unsnap, Unsnap All, and Flip Orientation are only accessible from the menu bar dropdown. The Organize action already has a configurable global shortcut (`cmd+'`). This plan extends the same mechanism to the remaining four actions. A default of `""` (empty string) means "disabled" — no shortcut is registered. Users can opt in by setting a value in `config.yml`.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/ConfigData.swift` | Modify — add four fields to `ShortcutsConfig`, defaults, `missingKeys`, `mergedWithDefaults` |
| `UnnamedWindowManager/Config.swift` | Modify — add four accessors |
| `UnnamedWindowManager/ConfigLoader.swift` | Modify — add four fields to YAML template |
| `UnnamedWindowManager/Services/KeybindingService.swift` | Modify — refactor to multi-binding, skip empty strings |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — show shortcut hints in menu labels |

---

## Implementation Steps

### 1. Extend `ShortcutsConfig` in `ConfigData.swift`

Add four new optional fields:

```swift
struct ShortcutsConfig: Codable {
    var organize: String?
    var snap: String?
    var unsnap: String?
    var unsnapAll: String?
    var flipOrientation: String?
}
```

In `defaults`, set all four to `""`:

```swift
shortcuts: ShortcutsConfig(organize: "cmd+'", snap: "", unsnap: "", unsnapAll: "", flipOrientation: "")
```

In `missingKeys`, add:

```swift
check(s?.shortcuts?.snap,            "config.shortcuts.snap")
check(s?.shortcuts?.unsnap,          "config.shortcuts.unsnap")
check(s?.shortcuts?.unsnapAll,       "config.shortcuts.unsnapAll")
check(s?.shortcuts?.flipOrientation, "config.shortcuts.flipOrientation")
```

In `mergedWithDefaults()`, extend the `ShortcutsConfig` initialiser:

```swift
shortcuts: ShortcutsConfig(
    organize:        s?.shortcuts?.organize        ?? d.shortcuts!.organize,
    snap:            s?.shortcuts?.snap            ?? d.shortcuts!.snap,
    unsnap:          s?.shortcuts?.unsnap          ?? d.shortcuts!.unsnap,
    unsnapAll:       s?.shortcuts?.unsnapAll       ?? d.shortcuts!.unsnapAll,
    flipOrientation: s?.shortcuts?.flipOrientation ?? d.shortcuts!.flipOrientation
)
```

### 2. Add accessors to `Config.swift`

```swift
static var snapShortcut:            String { shared.s.shortcuts!.snap! }
static var unsnapShortcut:          String { shared.s.shortcuts!.unsnap! }
static var unsnapAllShortcut:       String { shared.s.shortcuts!.unsnapAll! }
static var flipOrientationShortcut: String { shared.s.shortcuts!.flipOrientation! }
```

### 3. Extend YAML template in `ConfigLoader.swift`

After the existing `organize` line in the `shortcuts` block:

```yaml
  shortcuts:
    # Global keyboard shortcut for Organize. Format: modifier+key (e.g. cmd+', cmd+shift+o). Empty string disables.
    organize: "\(sh.organize ?? "cmd+'")"
    # Global keyboard shortcut for Snap. Empty string disables.
    snap: "\(sh.snap ?? "")"
    # Global keyboard shortcut for Unsnap. Empty string disables.
    unsnap: "\(sh.unsnap ?? "")"
    # Global keyboard shortcut for Unsnap All. Empty string disables.
    unsnapAll: "\(sh.unsnapAll ?? "")"
    # Global keyboard shortcut for Flip Orientation. Empty string disables.
    flipOrientation: "\(sh.flipOrientation ?? "")"
```

### 4. Refactor `KeybindingService.swift` for multiple bindings

Replace the single `parsedModifiers`/`parsedKey` pair with a typed binding list:

```swift
private struct Binding {
    let modifiers: NSEvent.ModifierFlags
    let key: String
    let action: () -> Void
}

private var bindings: [Binding] = []
```

In `start()`, build the bindings list from all configured shortcuts, skipping empty or unparseable ones:

```swift
bindings = []
let candidates: [(String, () -> Void)] = [
    (Config.organizeShortcut,        { OrganizeHandler.organize() }),
    (Config.snapShortcut,            { SnapHandler.snap() }),
    (Config.unsnapShortcut,          { UnsnapHandler.unsnap() }),
    (Config.unsnapAllShortcut,       { UnsnapHandler.unsnapAll() }),
    (Config.flipOrientationShortcut, { OrientFlipHandler.flipOrientation() }),
]
for (shortcut, action) in candidates {
    guard !shortcut.isEmpty, let (mods, key) = parse(shortcut) else { continue }
    bindings.append(Binding(modifiers: mods, key: key, action: action))
}
guard !bindings.isEmpty else {
    Logger.shared.log("KeybindingService: no shortcuts configured")
    return
}
```

The tap callback iterates `service.bindings` and dispatches the first match (consuming the event):

```swift
for binding in service.bindings {
    guard flags == binding.modifiers,
          nsEvent.charactersIgnoringModifiers == binding.key else { continue }
    let action = binding.action
    DispatchQueue.main.async { action() }
    return nil // consume
}
return Unmanaged.passRetained(event)
```

The `stop()` and `restart()` methods remain unchanged.

Remove the single-shortcut log line. Log a summary instead:

```swift
Logger.shared.log("KeybindingService: registered \(bindings.count) shortcut(s)")
```

### 5. Update menu labels in `UnnamedWindowManagerApp.swift`

Add a local helper inside the `MenuBarExtra` content closure to format labels:

```swift
func label(_ base: String, _ shortcut: String) -> String {
    let display = KeybindingService.displayString(shortcut)
    return display.isEmpty ? base : "\(base) (\(display))"
}
```

Apply it to all four affected buttons:

```swift
Button(label("Snap",        Config.snapShortcut))            { SnapHandler.snap() }
Button(label("Unsnap",      Config.unsnapShortcut))          { UnsnapHandler.unsnap() }
Button(label("Unsnap all",  Config.unsnapAllShortcut))       { UnsnapHandler.unsnapAll() }
Button(label("Organize",    Config.organizeShortcut))        { OrganizeHandler.organize() }
// ...
Button(label(orientLabel,   Config.flipOrientationShortcut)) { ... }
```

---

## Key Technical Notes

- Empty string `""` is a valid non-nil value — `mergedWithDefaults()` uses it as the default. Fields absent from YAML are `nil` and fall back to `""` from defaults. The result is always a non-nil `String`.
- `parse()` returns `nil` for empty strings because `tokens.count >= 2` fails. The `guard !shortcut.isEmpty` check short-circuits before calling `parse()`, keeping the log clean.
- The CGEventTap is shared across all bindings. Only one tap is created regardless of how many shortcuts are active.
- `displayString("")` returns `""` (the `tokens.count >= 2` guard fails), so the label helper correctly omits the hint.
- `OrientFlipHandler.flipOrientation()` called from a global key event fires without menu context — it already uses `focusedTrackedKey()` which scans AX elements directly, so it is safe to call from a background dispatch to main.
- `SnapHandler.snap()` uses `NSWorkspace.shared.frontmostApplication` — calling it via shortcut while another app is focused is the intended use case.

---

## Verification

1. Add `snap: "cmd+shift+s"` to `config.yml` → reload → press `Cmd+Shift+S` → focused window snaps into layout
2. Add `unsnap: "cmd+shift+u"` → reload → press shortcut → focused snapped window is removed
3. Add `unsnapAll: "cmd+shift+w"` → reload → press shortcut → all snapped windows are removed
4. Add `flipOrientation: "cmd+shift+f"` → reload → press shortcut → parent container orientation flips
5. Leave all four as `""` (defaults) → no shortcut fires, menu labels show plain text without parentheses
6. Set `organize: ""` → reload → `cmd+'` no longer fires
7. Reset config file → all four new fields appear in the regenerated YAML as empty strings
8. Reload config → log shows "registered N shortcut(s)" for however many are non-empty
