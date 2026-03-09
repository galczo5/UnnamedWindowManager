# Plan: 16_configurable_colors — Configurable Dim and Overlay Colors

## Checklist

- [ ] Add `dimColor` to `ConfigData.BehaviorConfig`
- [ ] Add `overlayColor` to `ConfigData.OverlayConfig`
- [ ] Update `ConfigData.defaults`, `missingKeys`, and `mergedWithDefaults`
- [ ] Add `SystemColor` helper that maps string → `NSColor`
- [ ] Replace hardcoded `overlayFillColor`/`overlayBorderColor` constants in `Config.swift`
- [ ] Update `WindowOpacityService` to use `Config.dimColor`
- [ ] Update `SwapOverlay` to re-apply color on every `show()` call
- [ ] Update `ConfigLoader.format` YAML output with new keys and comments

---

## Context / Problem

Two colors are currently hardcoded:

1. **Dim overlay color** — `NSColor.black` in `WindowOpacityService.dim()`. Users may prefer a different tint (e.g. white for light-mode setups).
2. **Swap overlay color** — `NSColor.systemBlue` in `Config.overlayFillColor`/`overlayBorderColor`. Users may want a different accent color.

The goal is to expose both as string-based config keys that map to macOS system colors, keeping the surface area small and ensuring colors look correct in both light and dark mode.

---

## System color set

Accepted color names (case-insensitive) for both keys:

`blue`, `red`, `green`, `orange`, `yellow`, `pink`, `purple`, `teal`, `indigo`, `brown`, `mint`, `cyan`, `gray`, `black`, `white`

Any unrecognised value falls back to the default silently (same pattern as other invalid config values — use `mergedWithDefaults`).

`black` and `white` map to `NSColor.black` / `NSColor.white` (not adaptive). All others map to `NSColor.system*`.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/System/SystemColor.swift` | **New file** — string-to-NSColor mapping |
| `UnnamedWindowManager/ConfigData.swift` | Add `dimColor: String?` and `overlayColor: String?` |
| `UnnamedWindowManager/Config.swift` | Replace hardcoded color constants with dynamic computed properties |
| `UnnamedWindowManager/Services/WindowOpacityService.swift` | Use `Config.dimColor` instead of `NSColor.black` |
| `UnnamedWindowManager/Observation/SwapOverlay.swift` | Re-apply overlay color on every `show()` call |
| `UnnamedWindowManager/ConfigLoader.swift` | Add new keys to YAML format output |

---

## Implementation Steps

### 1. Create `SystemColor.swift`

A single pure mapping from string to `NSColor`. No dependencies.

```swift
// Maps config color name strings to NSColor system colors.
struct SystemColor {
    static func resolve(_ name: String) -> NSColor? {
        switch name.lowercased() {
        case "blue":    return .systemBlue
        case "red":     return .systemRed
        case "green":   return .systemGreen
        case "orange":  return .systemOrange
        case "yellow":  return .systemYellow
        case "pink":    return .systemPink
        case "purple":  return .systemPurple
        case "teal":    return .systemTeal
        case "indigo":  return .systemIndigo
        case "brown":   return .systemBrown
        case "mint":    return .systemMint
        case "cyan":    return .systemCyan
        case "gray":    return .systemGray
        case "black":   return .black
        case "white":   return .white
        default:        return nil
        }
    }
}
```

### 2. Update `ConfigData`

In `BehaviorConfig`, add:
```swift
var dimColor: String?
```

In `OverlayConfig`, add:
```swift
var overlayColor: String?
```

Update `defaults`:
- `dimColor: "black"` in `BehaviorConfig`
- `overlayColor: "blue"` in `OverlayConfig`

Add to `missingKeys`:
```swift
check(s?.behavior?.dimColor,      "config.behavior.dimColor")
check(s?.overlay?.overlayColor,   "config.overlay.overlayColor")
```

Add to `mergedWithDefaults` behavior and overlay sections:
```swift
dimColor: s?.behavior?.dimColor ?? d.behavior!.dimColor,
overlayColor: s?.overlay?.overlayColor ?? d.overlay!.overlayColor,
```

### 3. Update `Config.swift`

Remove the two `static let` constants and replace with dynamic computed properties:

```swift
static var overlayFillColor: NSColor {
    let base = SystemColor.resolve(shared.s.overlay!.overlayColor!) ?? .systemBlue
    return base.withAlphaComponent(0.2)
}
static var overlayBorderColor: NSColor {
    let base = SystemColor.resolve(shared.s.overlay!.overlayColor!) ?? .systemBlue
    return base.withAlphaComponent(0.8)
}
static var dimColor: NSColor {
    SystemColor.resolve(shared.s.behavior!.dimColor!) ?? .black
}
```

### 4. Update `WindowOpacityService`

In `dim(focusedHash:)`, replace:
```swift
NSColor.black.withAlphaComponent(1 - Config.dimInactiveOpacity).cgColor
```
with:
```swift
Config.dimColor.withAlphaComponent(1 - Config.dimInactiveOpacity).cgColor
```

### 5. Update `SwapOverlay`

Currently colors are applied only when `window == nil` (first creation). Move color application to run every time `show()` is called so config reloads take effect and so the colors are fresh on each drag:

```swift
func show(frame: CGRect, belowWindow windowNumber: Int?) {
    if window == nil {
        let win = NSWindow(...)
        // ... window setup, no color here ...
        window = win
    }
    window?.contentView?.layer?.backgroundColor = Config.overlayFillColor.cgColor
    window?.contentView?.layer?.borderColor = Config.overlayBorderColor.cgColor
    window?.contentView?.layer?.borderWidth = Config.overlayBorderWidth
    window?.contentView?.layer?.cornerRadius = Config.overlayCornerRadius
    window?.setFrame(frame, display: false)
    // ... ordering ...
}
```

### 6. Update `ConfigLoader.format`

Add after `dimAnimationDuration`:
```
# Color of the dim overlay (black, white, blue, red, green, orange, yellow, pink, purple, teal, indigo, brown, mint, cyan, gray).
dimColor: \(bh.dimColor ?? "black")
```

Add after `borderWidth` in the overlay section:
```
# Accent color of the drop-zone overlay (black, white, blue, red, green, orange, yellow, pink, purple, teal, indigo, brown, mint, cyan, gray).
overlayColor: \(ov.overlayColor ?? "blue")
```

---

## Key Technical Notes

- `SystemColor.resolve` returns `nil` for unrecognised names; callers fall back to the hardcoded default so a typo in config doesn't crash
- `overlayFillColor` and `overlayBorderColor` are now computed (not `let`), so they re-read config on every access — this is fine since `SwapOverlay.show()` calls them per drag
- The `dimColor` alpha is controlled separately by `dimInactiveOpacity`, so black at 0.8 opacity produces the same result as the current hardcode
- Moving color application out of the `window == nil` block in `SwapOverlay` means the layer properties are set unconditionally on each `show()` — acceptable since drag events are infrequent

---

## Verification

1. Build and launch → default config written with `dimColor: black` and `overlayColor: blue`
2. Drag a snapped window → overlay appears in blue (unchanged from current behavior)
3. Set `overlayColor: red` in config, reload → drag a window → overlay appears in red
4. Set `dimColor: white` in config, reload → focus a snapped window → dim overlay is white tint
5. Set `overlayColor: invalid` in config → app falls back to blue without crashing
6. Check light and dark mode → system colors adapt correctly for `systemBlue` etc.; `black`/`white` stay fixed
