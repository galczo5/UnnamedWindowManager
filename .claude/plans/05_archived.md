# Plan: 05_archived — [ARCHIVED] Core Features, Tile Rename, and Scrolling Root Foundation

> **Archived** — This entry consolidates plans 05 through 18: `05_screen_change_reflow`, `06_configurable_colors`, `07_reset_and_refresh_menu`, `08_reapply_debounce`, `09_pre_snap_frame`, `10_inner_outer_gaps`, `11_custom_commands`, `12_rename_snap_to_tile`, `13_scrolling_root_slot`, `14_stacking_slot`, `15_scrolling_root_activation`, `16_scrolling_focus_navigation`, `17_scrolling_position_guard`, `18_stacking_slot_remove_order`.
> These plans have been completed and their details removed. Only key context is preserved.

---

## What This Covered

These plans built out the core feature set of the app: screen change reflow, configurable dim/overlay colors, Reset/Refresh menu actions, debounced layout reapplication, pre-tile frame restoration on untile, separate inner/outer gap config, user-defined shell command shortcuts, and a full rename of the "snap/unsnap" terminology to "tile/untile". The second half introduced the scrolling root layout: `RootSlot`/`ScrollingRootSlot`/`StackingSlot` model types, `ScrollingTileService`, `ScrollingLayoutService`, `ScrollingFocusService`, and the position guard that keeps scrolling windows snapped to their slots. `StackingOrder` was later removed in favour of always keeping the last child on top.

---

## Plans Consolidated

| Original # | Name | Summary |
|---|---|---|
| 05 | `05_screen_change_reflow` | Added `ScreenChangeObserver` to reflow layout when display configuration changes |
| 06 | `06_configurable_colors` | Made dim and swap-overlay colors configurable via `dimColor`/`overlayColor` config keys |
| 07 | `07_reset_and_refresh_menu` | Added Reset layout and Refresh menu items with optional keyboard shortcuts |
| 08 | `08_reapply_debounce` | Added 100ms debounce to `ReapplyHandler.reapplyAll()` and internalized validator scheduling |
| 09 | `09_pre_snap_frame` | Stored pre-tile origin/size in `WindowSlot` and restored them on untile via `RestoreService` |
| 10 | `10_inner_outer_gaps` | Split `gap` into `innerGap` and `outerGaps` (per-side) in config and all services |
| 11 | `11_custom_commands` | Added `commands` config section for user-defined global shortcuts that run shell commands |
| 12 | `12_rename_snap_to_tile` | Renamed all snap/unsnap symbols, files, config keys, and menu labels to tile/untile |
| 13 | `13_scrolling_root_slot` | Introduced `ScrollingRootSlot`, `RootSlot` enum, and changed `SharedRootStore.roots` to `[UUID: RootSlot]` |
| 14 | `14_stacking_slot` | Added `StackingSlot` struct and `.stacking` case to `Slot`, with layout and position service support |
| 15 | `15_scrolling_root_activation` | Wired up the Scroll menu button, `ScrollingTileService`, `ScrollingLayoutService`, and `ScrollingRootHandler` end-to-end |
| 16 | `16_scrolling_focus_navigation` | Made focus-left/right scroll the scrolling root, moving windows between left/center/right zones |
| 17 | `17_scrolling_position_guard` | Fixed position/resize guard for scrolling-root windows so they snap back on drag/resize |
| 18 | `18_stacking_slot_remove_order` | Removed `StackingOrder` enum; last child of a `StackingSlot` is always raised to the top |

---

## Important Files

`UnnamedWindowManager/Observation/ScreenChangeObserver.swift`
`UnnamedWindowManager/System/SystemColor.swift`
`UnnamedWindowManager/Services/CommandService.swift`
`UnnamedWindowManager/System/RestoreService.swift`
`UnnamedWindowManager/Model/ScrollingRootSlot.swift`
`UnnamedWindowManager/Model/RootSlot.swift`
`UnnamedWindowManager/Model/StackingSlot.swift`
`UnnamedWindowManager/Model/StackingAlign.swift`
`UnnamedWindowManager/Services/ScrollingTileService.swift`
`UnnamedWindowManager/Services/ScrollingPositionService.swift`
`UnnamedWindowManager/System/ScrollingLayoutService.swift`
`UnnamedWindowManager/System/ScrollingRootHandler.swift`
`UnnamedWindowManager/System/ScrollingFocusService.swift`
`UnnamedWindowManager/Services/TileService.swift`
`UnnamedWindowManager/System/TileHandler.swift`
`UnnamedWindowManager/System/UntileHandler.swift`
`UnnamedWindowManager/Observation/AutoTileObserver.swift`
`UnnamedWindowManager/Model/Slot.swift`
`UnnamedWindowManager/ConfigData.swift`
`UnnamedWindowManager/Config.swift`
`UnnamedWindowManager/ConfigLoader.swift`
`UnnamedWindowManager/Services/SharedRootStore.swift`
`UnnamedWindowManager/System/ReapplyHandler.swift`
`UnnamedWindowManager/System/LayoutService.swift`
`UnnamedWindowManager/Observation/ResizeObserver.swift`
`UnnamedWindowManager/Observation/PostResizeValidator.swift`
`UnnamedWindowManager/Services/KeybindingService.swift`
`UnnamedWindowManager/UnnamedWindowManagerApp.swift`

---
