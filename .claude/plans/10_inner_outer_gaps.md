# Plan: 10_inner_outer_gaps — Separate inner and outer gap settings

## Checklist

- [x] Replace `gap` with `innerGap` and `outerGaps` in `ConfigData.LayoutConfig`
- [x] Add `OuterGapsConfig` struct with `left`, `top`, `right`, `bottom` fields
- [x] Update `ConfigData.defaults`, `missingKeys`, and `mergedWithDefaults`
- [x] Replace `Config.gap` with `Config.innerGap` and `Config.outerGaps`
- [x] Update `ConfigLoader.format` for new YAML shape
- [x] Update `LayoutService.applyLayout` to use outer gaps for root origin, inner gaps for windows
- [x] Update `SnapService` root size computation to use outer gaps
- [x] Update `ResizeService` to use inner gap
- [x] Update `PostResizeValidator` to use inner gap
- [x] Update `FocusDirectionService` to use outer/inner gaps
- [x] Update `ReapplyHandler.clampSize` to use outer gaps

---

## Context / Problem

Currently there is a single `gap` config value (default `5`) used for both:
1. **Outer gaps** — the margin between the outermost windows and the screen edges (applied at root origin and root size).
2. **Inner gaps** — the spacing between adjacent windows (applied at window leaf slots via `w.gaps`).

The goal is to split this into two independent settings:
- `innerGap: CGFloat` — gap between windows (single value, applied equally on all sides of each leaf).
- `outerGaps: { left, top, right, bottom }` — per-side margin at the screen edges.

---

## Behaviour spec

- Inner gap applies to each window leaf as before (inset on all 4 sides by `innerGap`), creating `innerGap * 2` between two adjacent windows.
- Outer gaps apply only at the root level: the root origin is shifted inward by `(outerGaps.left, outerGaps.top)` and the root size is reduced by `(left + right, top + bottom)`.
- When a user sets only `innerGap` or only `outerGaps`, the other uses its default.
- Backward compatibility: the old `gap` key is removed. A fresh config file gets the new keys.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/ConfigData.swift` | Modify — replace `gap` with `innerGap` + `outerGaps` struct |
| `UnnamedWindowManager/Config.swift` | Modify — replace `Config.gap` with `Config.innerGap` and `Config.outerGaps` |
| `UnnamedWindowManager/ConfigLoader.swift` | Modify — update YAML format for new keys |
| `UnnamedWindowManager/System/LayoutService.swift` | Modify — use outer gaps for root origin, inner gap for leaf insets |
| `UnnamedWindowManager/Services/SnapService.swift` | Modify — use outer gaps when computing root dimensions |
| `UnnamedWindowManager/Services/ResizeService.swift` | Modify — use `Config.innerGap` |
| `UnnamedWindowManager/Observation/PostResizeValidator.swift` | Modify — use `Config.innerGap` |
| `UnnamedWindowManager/Services/FocusDirectionService.swift` | Modify — use outer gaps for root origin, inner gap for leaf rects |
| `UnnamedWindowManager/System/ReapplyHandler.swift` | Modify — use outer gaps in `clampSize` |

---

## Implementation Steps

### 1. Add `OuterGapsConfig` and update `ConfigData`

In `ConfigData.swift`, add a nested struct and replace `gap`:

```swift
struct OuterGapsConfig: Codable {
    var left: CGFloat?
    var top: CGFloat?
    var right: CGFloat?
    var bottom: CGFloat?
}

struct LayoutConfig: Codable {
    var innerGap: CGFloat?
    var outerGaps: OuterGapsConfig?
    var fallbackWidthFraction: CGFloat?
    var maxWidthFraction: CGFloat?
    var maxHeightFraction: CGFloat?
}
```

Update `defaults`:
```swift
layout: LayoutConfig(
    innerGap: 5,
    outerGaps: OuterGapsConfig(left: 5, top: 5, right: 5, bottom: 5),
    fallbackWidthFraction: 0.4, ...
)
```

Update `missingKeys` to check all 5 new paths (`config.layout.innerGap`, `config.layout.outerGaps.left`, etc.).

Update `mergedWithDefaults` to merge the `OuterGapsConfig` fields individually.

### 2. Update `Config` accessors

Replace:
```swift
static var gap: CGFloat { shared.s.layout!.gap! }
```
With:
```swift
static var innerGap: CGFloat { shared.s.layout!.innerGap! }
static var outerGaps: ConfigData.OuterGapsConfig { shared.s.layout!.outerGaps! }
```

### 3. Update `ConfigLoader.format`

Replace the single `gap` line with:

```yaml
layout:
  # Gap between adjacent snapped windows (points).
  innerGap: 5
  # Gaps between outermost windows and screen edges (points).
  outerGaps:
    left: 5
    top: 5
    right: 5
    bottom: 5
```

### 4. Update `LayoutService`

Root origin uses outer gaps:

```swift
let og = Config.outerGaps
let origin = CGPoint(
    x: visible.minX + og.left!,
    y: primaryHeight - visible.maxY + og.top!
)
```

Window leaf inset uses inner gap (no change to the `w.gaps` logic, just reference `Config.innerGap` instead of `Config.gap`).

### 5. Update `SnapService` root size computation

Every call to `position.recomputeSizes` currently passes `width - Config.gap * 2`. Replace with:

```swift
let og = Config.outerGaps
position.recomputeSizes(&store.roots[id]!,
                        width:  screen.visibleFrame.width  - og.left! - og.right!,
                        height: screen.visibleFrame.height - og.top!  - og.bottom!)
```

This affects 7 call sites in `SnapService` (`snap`, `removeAndReflow`, `resize`, `recomputeVisibleRootSizes`, `flipParentOrientation`, `insertAdjacent`, and the initial root creation already sets width/height from `visibleFrame` directly — that's fine since `recomputeSizes` overrides it).

### 6. Update `ResizeService`

Replace `Config.gap` with `Config.innerGap`:

```swift
let gap = w.gaps ? Config.innerGap * 2 : 0
```

### 7. Update `PostResizeValidator`

Same replacement:

```swift
let gap = w.gaps ? Config.innerGap * 2 : 0
```

### 8. Update `FocusDirectionService`

Root origin computation — same as LayoutService (use outer gaps).

Leaf rect computation — use `Config.innerGap` instead of `Config.gap`.

### 9. Update `ReapplyHandler.clampSize`

```swift
let og = Config.outerGaps
let maxH = visible.height * Config.maxHeightFraction - og.top! - og.bottom!
```

---

## Key Technical Notes

- `Config.outerGaps` returns a struct with non-optional values after merging with defaults, but the type uses optionals for YAML parsing. All call sites force-unwrap since merging guarantees non-nil.
- The inner gap creates `innerGap * 2` visual spacing between two adjacent windows (each window insets by `innerGap` on all sides). This is unchanged from current behaviour.
- Outer gaps are asymmetric — the root origin shifts by `(left, top)` and the root size shrinks by `(left + right, top + bottom)`.
- The `gaps: Bool` flag on slots still controls whether *any* gap applies. When `gaps == false`, both inner and outer gaps are bypassed for that slot.

---

## Verification

1. Build the project → compiles without errors
2. Delete `~/.config/unnamed/config.yml`, launch → new config file has `innerGap` and `outerGaps` section
3. Set `innerGap: 0`, `outerGaps: { left: 20, top: 20, right: 20, bottom: 20 }` → windows touch each other but have 20pt margins from screen edges
4. Set `innerGap: 10`, `outerGaps: { left: 0, top: 0, right: 0, bottom: 0 }` → windows have 10pt spacing but touch screen edges
5. Set asymmetric outer gaps (e.g. `left: 0, top: 30, right: 0, bottom: 0`) → only top edge has a margin
6. Resize a window by dragging → resize service correctly accounts for inner gap
7. Focus navigation (ctrl+opt+arrow) → correctly targets adjacent windows with new gap values
