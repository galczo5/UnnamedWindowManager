# Plan: 01_archived — [ARCHIVED] Foundation, Tiling Model, and Scroll/Pivot

> **Archived** — This entry consolidates plans [01_init, 02_resize, 03_horizontal, 04_horizontal_resize, 05_swap, 06_constraints, 07_drop_zones, 08_vertical_split, 09_new_model_structure, 10_model_naming, 11_new_drop_zones, 12_window_events, 13_hide_windows, 14_horizontal_scroll, 15_focus_scroll, 16_focus_scroll_debug, 17_logger, 18_remove_scroll].
> These plans have been completed and their details removed. Only key context is preserved.

---

## What This Covered

Plans 01–08 established the foundational macOS menu bar window manager: AX-based window snapping, persistent snap state with move/resize guards, slot-based horizontal tiling, per-window width/height storage, drag-to-swap, size constraints, left/center/right drop zones, and a vertical split zone. Plans 09–11 replaced the flat `[SnapKey: SnapEntry]` model with a hierarchical `ManagedSlotRegistry → [ManagedSlot] → [ManagedWindow]` structure, renamed all types for clarity, and redesigned drop zones to support top/bottom/left/right/center insert semantics. Plans 12–13 added window-close reflow, auto-snap of new windows via `kAXWindowCreatedNotification`, and auto-minimization of off-screen slots. Plans 14–16 introduced a horizontal scroll offset (`CurrentOffset`) and focus-triggered auto-scroll, then fixed edge cases around already-focused windows and unminimization side effects. Plan 17 added a file-backed `Logger` singleton. Plan 18 removed the entire scroll feature (pivoting away from a scrollable-canvas model to traditional fixed-slot tiling) while keeping the logger.

---

## Plans Consolidated

| Original # | Name | Summary |
|---|---|---|
| 01 | `01_init` | Initial macOS menu bar app with AX-based snap left/right via Accessibility APIs |
| 02 | `02_resize` | Persistent snap state and AX observer to reapply snap on user move/resize |
| 03 | `03_horizontal` | Right-side horizontal tiling with slot-based registry growing leftward |
| 04 | `04_horizontal_resize` | Per-window width/height storage; user resize accepted and layout reflowed |
| 05 | `05_swap` | Drag-to-swap snapped windows by detecting mid-X drop over another slot |
| 06 | `06_constraints` | Per-window size limits (80 % max width, full-height cap) enforced at snap and resize |
| 07 | `07_drop_zones` | Left/center/right drop zones per window for insert-before, swap, insert-after |
| 08 | `08_vertical_split` | Bottom drop zone for vertical split; `row` field in `SnapEntry` for stacked windows |
| 09 | `09_new_model_structure` | Replaced flat map with hierarchical `SnapRegistry → [SnapSlot] → [SlotWindow]` |
| 10 | `10_model_naming` | Renamed all types: `SnapWindow→ManagedWindow`, `SnapSlot→ManagedSlot`, `SnapRegistry→ManagedSlotRegistry` |
| 11 | `11_new_drop_zones` | Redesigned 5-zone system: left/top/center/bottom/right; individual window swap; no slot limit on vertical inserts |
| 12 | `12_window_events` | Window-close reflow with height equalization; auto-snap new windows via `WindowEventMonitor` |
| 13 | `13_hide_windows` | Auto-minimize off-screen slots; restore on layout change; `WindowVisibilityManager` |
| 14 | `14_horizontal_scroll` | `CurrentOffset` singleton; "Scroll Left/Right" menu items; offset applied to all layout math |
| 15 | `15_focus_scroll` | Focus-triggered auto-scroll: focused slot centered on screen after mouse-up |
| 16 | `16_focus_scroll_debug` | Fixed focus-scroll for already-focused windows via global mouseDown monitor; tuned suppression timing |
| 17 | `17_logger` | File-backed `Logger` singleton appending to `~/.unnamed.log`; logging for resize, position, offset, focus |
| 18 | `18_remove_scroll` | Removed entire scroll feature (`CurrentOffset`, scroll menu items, focus-scroll logic); kept `Logger` |

---

## Important Files

`UnnamedWindowManager/UnnamedWindowManagerApp.swift`
`UnnamedWindowManager/Model/ManagedTypes.swift`
`UnnamedWindowManager/Model/ManagedSlotRegistry.swift`
`UnnamedWindowManager/Model/ManagedSlotRegistry+SlotMutations.swift`
`UnnamedWindowManager/Snapping/SnapLayout.swift`
`UnnamedWindowManager/Snapping/WindowSnapper.swift`
`UnnamedWindowManager/Observation/ResizeObserver.swift`
`UnnamedWindowManager/Observation/ResizeObserver+Reapply.swift`
`UnnamedWindowManager/Observation/ResizeObserver+SwapOverlay.swift`
`UnnamedWindowManager/Observation/WindowEventMonitor.swift`
`UnnamedWindowManager/Observation/WindowVisibilityManager.swift`
`UnnamedWindowManager/Logger.swift`
`UnnamedWindowManager/Config.swift`
`UnnamedWindowManager/Info.plist`
`UnnamedWindowManager/UnnamedWindowManager.entitlements`

---
