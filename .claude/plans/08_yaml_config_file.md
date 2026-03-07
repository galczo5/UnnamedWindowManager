# Plan: 08_yaml_config_file — Load configuration from ~/.config/unnamed/config.yml

## Checklist

- [x] Add Yams (YAML parser) SPM dependency to the Xcode project
- [x] Create `ConfigData.swift` — Codable struct mirroring Config properties
- [x] Create `ConfigLoader.swift` — read/parse/write YAML, merge with defaults
- [x] Rewrite `Config.swift` — mutable singleton backed by ConfigData
- [x] Update all `Config.<prop>` call sites (no API change needed if done right)
- [x] Add "Open config file" menu item
- [x] Add "Reload config file" menu item
- [x] Wire config load into app startup
- [x] Verify build and manual test

---

## Context / Problem

All configuration lives in `Config.swift` as hardcoded `static let` constants. Users cannot customise behaviour (gaps, drop zones, auto-snap, etc.) without recompiling.

**Goal:** Store configuration in `~/.config/unnamed/config.yml`. On launch, read the file (or create it from defaults if missing). If the file exists but is incomplete, fill in missing keys from defaults and log each missing property. Provide two menu items — "Open config file" (opens in default editor) and "Reload config file" (re-reads YAML and reapplies layout).

---

## YAML file format

The file maps directly to the configurable subset of `Config`. Color/NSColor properties (`overlayFillColor`, `overlayBorderColor`) and `logFilePath` are kept out of the YAML — they are internal concerns.

```yaml
# ~/.config/unnamed/config.yml
gap: 5
fallbackWidthFraction: 0.4
maxWidthFraction: 0.80
maxHeightFraction: 1.0
dropZoneFraction: 0.20
dropZoneBottomFraction: 0.20
dropZoneTopFraction: 0.20
overlayCornerRadius: 8
overlayBorderWidth: 3
autoSnap: true
autoOrganize: true
```

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager.xcodeproj` | Modify — add Yams SPM dependency |
| `UnnamedWindowManager/ConfigData.swift` | **New file** — `Codable` struct with all YAML-exposed fields |
| `UnnamedWindowManager/ConfigLoader.swift` | **New file** — reads, parses, writes, and merges YAML config |
| `UnnamedWindowManager/Config.swift` | Modify — change from static-let enum to mutable singleton backed by `ConfigData` |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — add menu items, load config at startup |

---

## Implementation Steps

### 1. Add Yams SPM dependency

Add the [Yams](https://github.com/jpsim/Yams) Swift package to the Xcode project. Yams is the standard pure-Swift YAML parser with zero dependencies.

In Xcode: File > Add Package Dependencies > `https://github.com/jpsim/Yams.git`, version rule "Up to Next Major" from `5.0.0`. Link the `Yams` library to the `UnnamedWindowManager` target.

This will add a `Package.resolved` and modify `project.pbxproj`.

### 2. Create `ConfigData.swift`

A plain `Codable` struct whose properties map 1:1 to YAML keys. Every property is `Optional` so partial YAML files decode successfully — missing keys become `nil` and get filled from defaults.

```swift
import CoreGraphics

/// Decoded representation of config.yml. All fields optional to allow partial files.
struct ConfigData: Codable {
    var gap: CGFloat?
    var fallbackWidthFraction: CGFloat?
    var maxWidthFraction: CGFloat?
    var maxHeightFraction: CGFloat?
    var dropZoneFraction: CGFloat?
    var dropZoneBottomFraction: CGFloat?
    var dropZoneTopFraction: CGFloat?
    var overlayCornerRadius: CGFloat?
    var overlayBorderWidth: CGFloat?
    var autoSnap: Bool?
    var autoOrganize: Bool?

    static let defaults = ConfigData(
        gap: 5,
        fallbackWidthFraction: 0.4,
        maxWidthFraction: 0.80,
        maxHeightFraction: 1.0,
        dropZoneFraction: 0.20,
        dropZoneBottomFraction: 0.20,
        dropZoneTopFraction: 0.20,
        overlayCornerRadius: 8,
        overlayBorderWidth: 3,
        autoSnap: true,
        autoOrganize: true
    )

    /// Returns a copy where every nil field is filled from `defaults`, logging each substitution.
    func mergedWithDefaults() -> ConfigData {
        let d = ConfigData.defaults
        var result = self
        let mirror = Mirror(reflecting: self)
        for child in mirror.children {
            guard let label = child.label else { continue }
            // If the value is Optional and nil, log and fill from defaults
            if case Optional<Any>.none = child.value {
                Logger.shared.log("Config: missing '\(label)', using default")
            }
        }
        result.gap = gap ?? d.gap
        result.fallbackWidthFraction = fallbackWidthFraction ?? d.fallbackWidthFraction
        result.maxWidthFraction = maxWidthFraction ?? d.maxWidthFraction
        result.maxHeightFraction = maxHeightFraction ?? d.maxHeightFraction
        result.dropZoneFraction = dropZoneFraction ?? d.dropZoneFraction
        result.dropZoneBottomFraction = dropZoneBottomFraction ?? d.dropZoneBottomFraction
        result.dropZoneTopFraction = dropZoneTopFraction ?? d.dropZoneTopFraction
        result.overlayCornerRadius = overlayCornerRadius ?? d.overlayCornerRadius
        result.overlayBorderWidth = overlayBorderWidth ?? d.overlayBorderWidth
        result.autoSnap = autoSnap ?? d.autoSnap
        result.autoOrganize = autoOrganize ?? d.autoOrganize
        return result
    }
}
```

### 3. Create `ConfigLoader.swift`

Handles file-system operations: ensure directory exists, create default file, read & parse, reload.

```swift
import Foundation
import Yams

/// Reads and writes ~/.config/unnamed/config.yml.
struct ConfigLoader {
    static let directoryPath = NSHomeDirectory() + "/.config/unnamed"
    static let filePath = directoryPath + "/config.yml"

    /// Loads config from disk. Creates the file from defaults if it does not exist.
    static func load() -> ConfigData {
        let fm = FileManager.default

        // Ensure directory exists.
        if !fm.fileExists(atPath: directoryPath) {
            try? fm.createDirectory(atPath: directoryPath,
                                    withIntermediateDirectories: true)
        }

        // If no file, write defaults and return them.
        if !fm.fileExists(atPath: filePath) {
            let defaults = ConfigData.defaults
            write(defaults)
            Logger.shared.log("Config: created default config at \(filePath)")
            return defaults
        }

        // Parse existing file.
        guard let contents = fm.contents(atPath: filePath),
              let yaml = String(data: contents, encoding: .utf8) else {
            Logger.shared.log("Config: could not read \(filePath), using defaults")
            return ConfigData.defaults
        }

        do {
            let decoder = YAMLDecoder()
            let parsed = try decoder.decode(ConfigData.self, from: yaml)
            return parsed.mergedWithDefaults()
        } catch {
            Logger.shared.log("Config: parse error — \(error.localizedDescription), using defaults")
            return ConfigData.defaults
        }
    }

    /// Writes a ConfigData to the YAML file.
    static func write(_ data: ConfigData) {
        do {
            let encoder = YAMLEncoder()
            let yaml = try encoder.encode(data)
            try yaml.write(toFile: filePath, atomically: true, encoding: .utf8)
        } catch {
            Logger.shared.log("Config: failed to write config — \(error.localizedDescription)")
        }
    }
}
```

### 4. Rewrite `Config.swift`

Change from a static-let enum to a class with mutable properties. A `reload()` method re-reads the YAML. All existing call sites (`Config.gap`, `Config.autoSnap`, etc.) keep working — they become computed properties that read from the backing `ConfigData`.

```swift
import CoreGraphics
import AppKit

/// Runtime configuration, loaded from ~/.config/unnamed/config.yml.
final class Config {
    static let shared = Config()
    private var data: ConfigData

    private init() {
        data = ConfigLoader.load()
    }

    func reload() {
        data = ConfigLoader.load()
        Logger.shared.log("Config: reloaded from disk")
    }

    // MARK: - Accessors (keep static API so call sites don't change)

    static var gap: CGFloat { shared.data.gap! }
    static var fallbackWidthFraction: CGFloat { shared.data.fallbackWidthFraction! }
    static var maxWidthFraction: CGFloat { shared.data.maxWidthFraction! }
    static var maxHeightFraction: CGFloat { shared.data.maxHeightFraction! }
    static var dropZoneFraction: CGFloat { shared.data.dropZoneFraction! }
    static var dropZoneBottomFraction: CGFloat { shared.data.dropZoneBottomFraction! }
    static var dropZoneTopFraction: CGFloat { shared.data.dropZoneTopFraction! }
    static var overlayCornerRadius: CGFloat { shared.data.overlayCornerRadius! }
    static var overlayBorderWidth: CGFloat { shared.data.overlayBorderWidth! }
    static var autoSnap: Bool { shared.data.autoSnap! }
    static var autoOrganize: Bool { shared.data.autoOrganize! }

    // Non-YAML properties stay as constants.
    static let overlayFillColor: NSColor = .systemBlue.withAlphaComponent(0.2)
    static let overlayBorderColor: NSColor = .systemBlue.withAlphaComponent(0.8)
    static let logFilePath: String = NSHomeDirectory() + "/.unnamed.log"
}
```

Force-unwraps are safe because `mergedWithDefaults()` guarantees every field is filled before `data` is stored.

### 5. Update call sites

Because the static accessors keep the same names (`Config.gap`, `Config.autoSnap`, etc.), **no call-site changes are needed** — `static let` becomes `static var` with a computed getter, which is source-compatible.

The only change: `Config` goes from an `enum` to a `class`, so any pattern-match on `Config` (there are none) would break. Since `Config` is only used via dot-access, this is transparent.

### 6. Add menu items in `UnnamedWindowManagerApp.swift`

Insert two new buttons in the menu between "Debug" and "Quit":

```swift
Divider()
Button("Open config file") {
    NSWorkspace.shared.open(URL(fileURLWithPath: ConfigLoader.filePath))
}
Button("Reload config file") {
    Config.shared.reload()
    ReapplyHandler.reapplyAll()
}
Divider()
Button("Quit") { NSApplication.shared.terminate(nil) }
```

`NSWorkspace.shared.open(URL(fileURLWithPath:))` opens the `.yml` file in the user's default text editor (or whatever app is associated with `.yml`).

After reload, `ReapplyHandler.reapplyAll()` recomputes sizes and reapplies the layout so changed gap/fraction values take effect immediately.

### 7. Wire config load at startup

`Config.shared` is lazily initialized. The first access triggers `ConfigLoader.load()`. This already happens naturally because `UnnamedWindowManagerApp.init()` accesses `Config.autoSnap`. No extra wiring needed — just make sure `Config.shared` is referenced before any property access, which the static computed vars guarantee.

---

## Key Technical Notes

- Force-unwraps on `data` fields are safe only because `mergedWithDefaults()` fills every `nil`. If a new field is added to `ConfigData` but not to `mergedWithDefaults()`, it will crash at runtime — keep these in sync.
- `Config` is accessed from multiple threads (main thread + AX callback queue + logger queue). The current approach is safe because `reload()` is only called from the main thread (menu action) and Swift class property writes from the main thread are safe when reads happen after init. If concurrent mutation becomes a concern, add a dispatch queue.
- `YAMLEncoder` outputs keys in declaration order. The generated default file will be human-readable without extra formatting.
- `Logger` is initialized before `Config` is fully loaded in the current design (`Logger.init` reads `Config.logFilePath`). Since `logFilePath` stays a static `let`, there is no circular dependency.
- `NSWorkspace.shared.open(URL(fileURLWithPath:))` opens the file with the default app for `.yml`. If no app is associated, macOS shows the "Open with" dialog.
- Reload reapplies layout but does **not** restart `AutoSnapObserver`. If the user toggles `autoSnap`/`autoOrganize` via config, they need to restart the app for observer start/stop to take effect. This is acceptable for v1; a future iteration could handle observer lifecycle on reload.

---

## Verification

1. Delete `~/.config/unnamed/config.yml` if it exists. Launch app. Confirm the file is created with default values.
2. Open the YAML file, change `gap` to `20`. Click "Reload config file" in menu bar. Confirm windows re-snap with wider gaps.
3. Delete a key (e.g. remove `dropZoneFraction` line) from the YAML. Click "Reload config file". Check `~/.unnamed.log` for `Config: missing 'dropZoneFraction', using default`.
4. Put invalid YAML in the file (e.g. `gap: abc`). Click "Reload config file". Confirm app logs parse error and falls back to defaults without crashing.
5. Click "Open config file". Confirm the file opens in the default text editor.
6. Confirm all existing functionality (snap, unsnap, organize, flip, overlay) works unchanged with default config values.
