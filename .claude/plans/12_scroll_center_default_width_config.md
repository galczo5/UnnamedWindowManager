# Plan: 12_scroll_center_default_width_config — Configurable Scroll Center Default Width

## Checklist

- [x] Add `scrollCenterDefaultWidthFraction: CGFloat?` to `ConfigData.LayoutConfig`
- [x] Add default value `0.9` in `ConfigData.defaults`
- [x] Add key path to `ConfigData.missingKeys`
- [x] Add merge in `ConfigData.mergedWithDefaults`
- [x] Add `Config.scrollCenterDefaultWidthFraction` accessor
- [x] Update `ScrollingPositionService.recomputeSizes` to use `Config.scrollCenterDefaultWidthFraction` as fallback
- [ ] Add YAML comment to sample config

---

## Context / Problem

The center slot default width in scrolling mode is hardcoded as `0.8` in `ScrollingPositionService.recomputeSizes` (the `?? 0.8` fallback when `centerWidthFraction` is nil). The user wants this default to be configurable via `config.yml`, with a new default of **90%** (0.9).

`centerWidthFraction` in `ScrollingRootSlot` remains the per-session user-resize override. The config value is only the initial default used when no resize has been performed yet.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/ConfigData.swift` | Modify — add `scrollCenterDefaultWidthFraction` to `LayoutConfig`, defaults, missingKeys, mergedWithDefaults |
| `UnnamedWindowManager/Config.swift` | Modify — add `scrollCenterDefaultWidthFraction` static accessor |
| `UnnamedWindowManager/Services/ScrollingPositionService.swift` | Modify — replace `?? 0.8` with `?? Config.scrollCenterDefaultWidthFraction` |

---

## Implementation Steps

### 1. Add field to `ConfigData.LayoutConfig`

In `ConfigData.swift`, add to `LayoutConfig`:

```swift
struct LayoutConfig: Codable {
    var innerGap: CGFloat?
    var outerGaps: OuterGapsConfig?
    var fallbackWidthFraction: CGFloat?
    var maxWidthFraction: CGFloat?
    var maxHeightFraction: CGFloat?
    var scrollCenterDefaultWidthFraction: CGFloat?
}
```

### 2. Set default to 0.9 in `ConfigData.defaults`

```swift
layout: LayoutConfig(
    innerGap: 5,
    outerGaps: ...,
    fallbackWidthFraction: 0.4,
    maxWidthFraction: 0.80,
    maxHeightFraction: 1.0,
    scrollCenterDefaultWidthFraction: 0.9
),
```

### 3. Add to `missingKeys`

```swift
check(s?.layout?.scrollCenterDefaultWidthFraction, "config.layout.scrollCenterDefaultWidthFraction")
```

### 4. Add to `mergedWithDefaults`

```swift
layout: LayoutConfig(
    ...
    scrollCenterDefaultWidthFraction: s?.layout?.scrollCenterDefaultWidthFraction ?? d.layout!.scrollCenterDefaultWidthFraction
),
```

### 5. Add accessor in `Config.swift`

```swift
static var scrollCenterDefaultWidthFraction: CGFloat { shared.s.layout!.scrollCenterDefaultWidthFraction! }
```

### 6. Use config value in `ScrollingPositionService`

Replace:

```swift
let fraction = root.centerWidthFraction ?? 0.8
```

with:

```swift
let fraction = root.centerWidthFraction ?? Config.scrollCenterDefaultWidthFraction
```

---

## Key Technical Notes

- `centerWidthFraction` on `ScrollingRootSlot` (set by user drag-resize) takes precedence over the config default — the `??` chain handles this correctly.
- The clamp in `clampedCenterFraction` has a max of 0.90 — if the user sets a config value above 0.90, it will be used as the initial default but any drag-resize will be clamped to 0.90. This is fine; the config default is not clamped on read.
- No migration needed — existing sessions with `centerWidthFraction == nil` will pick up the new 0.9 default on next launch.

---

## Verification

1. Fresh launch with no config → scrolling root center slot opens at 90% of screen width.
2. Set `scrollCenterDefaultWidthFraction: 0.7` in config → reload → center opens at 70%.
3. Drag-resize center to a custom width → custom width is respected (config default no longer applies for that session).
4. Scroll left/right after setting config default → width remains at config default (no per-session override set).
