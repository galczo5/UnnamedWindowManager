# Plan: 21_audit_config — Move config files to Config/ directory and audit

## Checklist

- [x] Create `UnnamedWindowManager/Config/` directory
- [x] Move `Config.swift` → `Config/Config.swift`
- [x] Move `ConfigData.swift` → `Config/ConfigData.swift`
- [x] Move `ConfigLoader.swift` → `Config/ConfigLoader.swift`
- [x] Move `SystemColor.swift` → `Config/SystemColor.swift`
- [x] Audit and fix issues in `Config.swift`
- [x] Audit and fix issues in `ConfigData.swift`
- [x] Audit and fix issues in `ConfigLoader.swift`
- [x] Audit and fix issues in `SystemColor.swift`
- [x] Update CODE.md to reflect new directory
- [x] Build to verify

---

## Context / Problem

The three config files (`Config.swift`, `ConfigData.swift`, `ConfigLoader.swift`) currently live at the top level of `UnnamedWindowManager/` alongside the app entry point and delegate. `SystemColor.swift` lives in `Services/` but is purely a config helper (maps color name strings to `NSColor`). These files form a cohesive config domain and should be grouped in their own `Config/` directory.

The project uses `PBXFileSystemSynchronizedRootGroup`, so moving files on disk is sufficient — no pbxproj edits needed.

---

## Audit Findings

### Config.swift (67 lines)

| # | Category | Finding |
|---|----------|---------|
| 1 | Quality | Every static accessor force-unwraps through `shared.s.layout!.innerGap!` etc. After `mergedWithDefaults()`, nils are impossible, but a single missed default would crash at runtime. No action needed now (tracked as observation), since `mergedWithDefaults` guarantees non-nil. |
| 2 | Style | File is clean — has purpose comment, no boilerplate. |

### ConfigData.swift (194 lines)

| # | Category | Finding |
|---|----------|---------|
| 1 | Decomposition | At 194 lines the file is acceptable in size, but contains 7 nested struct types plus `missingKeys` and `mergedWithDefaults()`. The nested structs are tightly coupled to `ConfigData` and don't have independent callers, so keeping them nested is reasonable. |
| 2 | Quality | `missingKeys` manually enumerates every field — adding a new field requires updating this, `mergedWithDefaults()`, `defaults`, AND `format()` in ConfigLoader. This is error-prone but unavoidable without reflection. **No code change** — just noting the maintenance burden. |
| 3 | Quality | `scrollCenterDefaultWidthFraction` is missing from `format()` in ConfigLoader — it won't be written to the YAML file. This is a bug. |
| 4 | Style | File is clean. |

### ConfigLoader.swift (151 lines)

| # | Category | Finding |
|---|----------|---------|
| 1 | Quality | `format()` is missing `scrollCenterDefaultWidthFraction` in the layout section — new configs added to `ConfigData` won't appear in the generated YAML unless `format()` is also updated. **Bug fix needed.** |
| 2 | Quality | `format()` uses manual string interpolation for YAML — fragile but functional. No change needed. |
| 3 | Style | File is clean. |

### SystemColor.swift (25 lines)

| # | Category | Finding |
|---|----------|---------|
| 1 | Location | Currently in `Services/` but it's purely a config concern — maps color name strings from config to `NSColor`. Should move to `Config/`. |
| 2 | Style | File is clean. |

---

## Files to create / modify

| File | Action |
|------|--------|
| `Config/` | **New directory** |
| `Config/Config.swift` | Move from top level |
| `Config/ConfigData.swift` | Move from top level |
| `Config/ConfigLoader.swift` | Modify — fix missing `scrollCenterDefaultWidthFraction` in `format()` |
| `Config/SystemColor.swift` | Move from `Services/SystemColor.swift` |
| `CODE.md` | Modify — add Config section, remove config files from top-level and Services tables |

---

## Implementation Steps

### 1. Create Config/ directory and move files

Move all four files into `UnnamedWindowManager/Config/`.

### 2. Fix missing scrollCenterDefaultWidthFraction in ConfigLoader.format()

Add the missing line in the layout section of the YAML template, after `maxHeightFraction`:

```swift
            # Default width of the center slot in scroll mode as a fraction of the screen.
            scrollCenterDefaultWidthFraction: \(num(l.scrollCenterDefaultWidthFraction))
```

### 3. Update CODE.md

Add a new `## Config` section documenting the four files, remove them from their current locations in the document.

### 4. Build

Run `./build.sh` to confirm everything compiles.

---

## Key Technical Notes

- The project uses `PBXFileSystemSynchronizedRootGroup` — moving files on disk automatically updates Xcode's view. No pbxproj changes needed.
- `SystemColor` has no callers outside `Config.swift`, making it a natural fit for the `Config/` directory.

---

## Verification

1. Build succeeds after all moves
2. Launch app → config loads correctly from `~/.config/unnamed/config.yml`
3. Add `scrollCenterDefaultWidthFraction` to config, reload → value is respected
4. Delete config file, relaunch → default config is created with `scrollCenterDefaultWidthFraction` present
