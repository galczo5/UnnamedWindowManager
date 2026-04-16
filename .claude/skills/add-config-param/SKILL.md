---
name: add-config-param
description: Add a new parameter to the app config. Updates ConfigData, Config, and the YAML format with a comment. Use when the user wants to add a new config value that can be set in ~/.config/unnamed/config.yml.
argument-hint: <name> <group> <type> <default> "<description>"
---

Add a new config parameter across all required files. The parameter must be added consistently to 4 places and the YAML formatter.

## Arguments

Parse from `$ARGUMENTS` in this order:
- **name** — Swift property name (camelCase), e.g. `animationDuration`
- **group** — one of: `layout`, `overlay`, `behavior`
- **type** — Swift type: `CGFloat` or `Bool`
- **default** — default value, e.g. `0.3` or `true`
- **description** — human-readable comment for the YAML file, in quotes

If arguments are missing or ambiguous, ask the user before proceeding.

## Files to modify (in order)

### 1. `UnnamedWindowManager/ConfigData.swift`

Read the file first. Make three changes:

**a) Add property to the correct group struct** (`LayoutConfig`, `OverlayConfig`, or `BehaviorConfig`):
```swift
var <name>: <Type>?
```

**b) Add to `ConfigData.defaults`** — inside the matching group initialiser:
```swift
<name>: <default>
```

**c) Add to `missingKeys`** — one `check(...)` line using the full YAML key path:
```swift
check(s?.<group>?.<name>, "config.<group>.<name>")
```

**d) Add to `mergedWithDefaults()`** — inside the matching group constructor:
```swift
<name>: s?.<group>?.<name> ?? d.<group>!.<name>
```

### 2. `UnnamedWindowManager/Config.swift`

Read the file first. Add one static accessor in the appropriate position (keep related properties grouped):
```swift
static var <name>: <Type> { shared.s.<group>!.<name>! }
```

### 3. `UnnamedWindowManager/ConfigLoader.swift`

Read the file first. Inside `format(_ data:)`, add the parameter to the correct group block with a `#` comment line immediately above the value line:
```
# <description>
<name>: \(<accessor>)
```

The accessor depends on type:
- `CGFloat` → `\(num(<group>.<name>))`
- `Bool` → `\(<group>.<name> ?? <default>)`

Place it after the last existing entry in the group, matching the indentation of surrounding entries (4 spaces per YAML level: group headers at 2 spaces, entries at 4 spaces).

## After editing

Run the build to confirm no compiler errors:
```bash
xcodebuild -project UnnamedWindowManager.xcodeproj -scheme UnnamedWindowManager -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

Report success or surface any errors.

## Rules

- Never add a parameter without a description comment in `format()`.
- Keep properties in the same order across all four files.
- `missingKeys` and `mergedWithDefaults()` must stay in sync — every property in every struct must have an entry in both.
- Force-unwraps in `Config` accessors are safe only because `mergedWithDefaults()` guarantees all fields are filled.
