# Plan: 10_organize_shortcut — Global keyboard shortcut for Organize

## Checklist

- [ ] Add `ShortcutsConfig` struct and wire into `ConfigData`
- [ ] Add `organizeShortcut` accessor to `Config`
- [ ] Add `shortcuts` section to YAML format in `ConfigLoader`
- [ ] Create `KeybindingService.swift`
- [ ] Wire `KeybindingService` into app lifecycle

---

## Context / Problem

The "Organize" action is only available via the menu bar icon dropdown. There is no way to trigger it with a keyboard shortcut. The goal is to add a global hotkey (default `cmd+'`) that calls `OrganizeHandler.organize()`, configurable via `config.yml`.

---

## macOS capability note

SwiftUI `.keyboardShortcut` only works when the app menu is focused — useless for a menu-bar-only app. `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` fires globally and requires Accessibility trust, which the app already demands. This is the right mechanism.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/ConfigData.swift` | Modify — add `ShortcutsConfig` struct, defaults, `missingKeys`, `mergedWithDefaults` |
| `UnnamedWindowManager/Config.swift` | Modify — add `organizeShortcut` accessor |
| `UnnamedWindowManager/ConfigLoader.swift` | Modify — add `shortcuts` section to `format(_:)` |
| `UnnamedWindowManager/Services/KeybindingService.swift` | **New file** — global hotkey registration and dispatch |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — start/restart `KeybindingService` |

---

## Implementation Steps

### 1. Add `ShortcutsConfig` to `ConfigData.swift`

Add a new nested struct inside `ConfigData`:

```swift
struct ShortcutsConfig: Codable {
    var organize: String?
}
```

Wire it in:
- Add `var shortcuts: ShortcutsConfig?` to `ConfigSection`.
- Add default: `shortcuts: ShortcutsConfig(organize: "cmd+'")` in `ConfigData.defaults`.
- Add `check(s?.shortcuts?.organize, "config.shortcuts.organize")` in `missingKeys`.
- Add merge line in `mergedWithDefaults()`:
  ```swift
  shortcuts: ShortcutsConfig(
      organize: s?.shortcuts?.organize ?? d.shortcuts!.organize
  )
  ```

### 2. Add accessor to `Config.swift`

```swift
static var organizeShortcut: String { shared.s.shortcuts!.organize! }
```

### 3. Add `shortcuts` section to `ConfigLoader.format(_:)`

After the `behavior` block, add:

```swift
let sh = s?.shortcuts ?? d.shortcuts!
```

And in the template string:

```yaml
  shortcuts:
    # Global keyboard shortcut for Organize. Format: modifier+key (e.g. cmd+', cmd+shift+o).
    organize: \(sh.organize ?? "cmd+'")
```

### 4. Create `KeybindingService.swift`

Singleton at `Services/KeybindingService.swift`. Responsibilities:

- Parse shortcut strings like `"cmd+'"` into modifier flags + key character.
- Register a global event monitor via `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`.
- On match, call `OrganizeHandler.organize()` on the main thread.
- Provide `start()`, `stop()`, and `restart()` methods.

Parsing logic:
- Split on `+`. Last token is the key character. Preceding tokens map to modifiers: `cmd` → `.command`, `shift` → `.shift`, `ctrl` → `.control`, `alt`/`opt` → `.option`.
- Compare `event.charactersIgnoringModifiers` against the key character.
- Compare `event.modifierFlags.intersection(.deviceIndependentFlagsMask)` against expected modifiers.

### 5. Wire into `UnnamedWindowManagerApp.swift`

In `init()`:

```swift
KeybindingService.shared.start()
```

In "Reload config file" and "Reset config file" button actions, add:

```swift
KeybindingService.shared.restart()
```

---

## Key Technical Notes

- `NSEvent.addGlobalMonitorForEvents` silently does nothing if Accessibility trust is not granted — no crash, just no events. The app already prompts for trust elsewhere.
- `stop()` must call `NSEvent.removeMonitor(_:)` before `start()` re-registers, otherwise monitors accumulate on each config reload.
- The `'` (apostrophe) key reports as `"'"` in `charactersIgnoringModifiers` on US keyboards. Non-US layouts may differ — `charactersIgnoringModifiers` is still the most reliable approach.
- Modifier comparison must mask with `.deviceIndependentFlagsMask` to ignore hardware-specific bits (e.g. numlock).

---

## Verification

1. Launch the app → press `CMD+'` → all visible windows organize (same as clicking "Organize" in the menu)
2. Open `config.yml` → change `organize` to `cmd+shift+o` → click "Reload config file" → verify old shortcut stops working and new one works
3. Remove the `shortcuts` section from `config.yml` → reload → verify default `cmd+'` is used (logged as missing key, filled from defaults)
4. Reset config file → verify `shortcuts.organize` appears in the regenerated YAML
