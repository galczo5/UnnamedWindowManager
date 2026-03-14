# Plan: 06_archived — [ARCHIVED] Bug Fixes, Scrolling Polish, and Performance

> **Archived** — This entry consolidates plans 06 through 12: `06_fix_dim_infinite_loop`, `07_fix_focus_scroll_last_child`, `08_scrolled_menu_label`, `09_scrolling_layout_skip_unchanged`, `10_scrolling_root_dim`, `11_performance_analysis`, `12_performance_improvements`.
> These plans have been completed and their details removed. Only key context is preserved.

---

## What This Covered

These plans fixed the dim overlay infinite loop caused by `kAXRaiseAction` in `FocusObserver` (replaced with a debounced `executeDim` + `pendingDim` work item), corrected the `scrollLeft`/`scrollRight` stack semantics to use `removeLast`/`append` consistently, and added a `[scrolled]` menu bar label. Two scrolling-root optimisations followed: a `zonesChanged` flag to skip redundant stacking-slot AX calls during scroll, and dim-overlay support for scrolling roots (center slot stays above the overlay, side slots are dimmed). A full performance audit then drove a set of concrete improvements: `OnScreenWindowCache` to consolidate `CGWindowListCopyWindowInfo` calls, slot-tree-based drop-target detection to eliminate per-drag AX reads, skip-unchanged AX writes in `LayoutService`, and a `keysByHash` reverse index for O(1) window lookup in `ResizeObserver` and `FocusObserver`.

---

## Plans Consolidated

| Original # | Name | Summary |
|---|---|---|
| 06 | `06_fix_dim_infinite_loop` | Removed `kAXRaiseAction` from `FocusObserver` and added 100ms debounce to stop notification ping-pong loop |
| 07 | `07_fix_focus_scroll_last_child` | Fixed `scrollRight`/`scrollLeft` to use `removeLast`/`append` so the most-recently-visited window is always on top |
| 08 | `08_scrolled_menu_label` | Added `isScrolled` to `MenuState` and showed `[scrolled]` in the menu bar label when a scrolling root is visible |
| 09 | `09_scrolling_layout_skip_unchanged` | Added `zonesChanged` flag to skip stacking-slot AX calls and removed redundant `kAXRaiseAction` during scroll |
| 10 | `10_scrolling_root_dim` | Applied dim overlay to scrolling roots, anchoring it below the center slot window so side slots appear dimmed |
| 11 | `11_performance_analysis` | Audited AX call density, CGWindowList redundancy, linear searches, drag polling, and overlay overhead |
| 12 | `12_performance_improvements` | Implemented `OnScreenWindowCache`, slot-tree drop-target frames, skip-unchanged AX writes, and `keysByHash` O(1) lookup |

---

## Important Files

`UnnamedWindowManager/Observation/FocusObserver.swift`
`UnnamedWindowManager/Services/ScrollingTileService.swift`
`UnnamedWindowManager/UnnamedWindowManagerApp.swift`
`UnnamedWindowManager/System/ScrollingLayoutService.swift`
`UnnamedWindowManager/System/ScrollingFocusService.swift`
`UnnamedWindowManager/System/LayoutService.swift`
`UnnamedWindowManager/System/OnScreenWindowCache.swift`
`UnnamedWindowManager/System/ReapplyHandler.swift`
`UnnamedWindowManager/Observation/ResizeObserver.swift`
`UnnamedWindowManager/Observation/SwapOverlay.swift`
`UnnamedWindowManager/Services/TileService.swift`

---
