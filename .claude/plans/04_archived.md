# Plan: 04_archived — [ARCHIVED] Snap Shortcuts, Focus Direction, Dim Inactive Windows

> **Archived** — This entry consolidates plans 04_snap_shortcuts, 05_focus_direction, and 06_dim_inactive_windows.
> These plans have been completed and their details removed. Only key context is preserved.

---

## What This Covered

Added configurable global keyboard shortcuts for Snap, Unsnap, Unsnap All, and Flip Orientation actions (extending the existing Organize shortcut mechanism). Implemented spatial focus navigation via ctrl+opt+arrow keys to move focus between snapped windows using overlap-based nearest-neighbor selection. Added optional dimming of non-focused managed windows using private CGS APIs, controlled by `dimInactiveWindows` and `dimInactiveOpacity` config values.

---

## Plans Consolidated

| Original # | Name | Summary |
|---|---|---|
| 04 | `04_snap_shortcuts` | Added configurable global shortcuts for Snap, Unsnap, Unsnap All, and Flip Orientation; refactored KeybindingService to support multiple bindings |
| 05 | `05_focus_direction` | Implemented directional focus navigation (left/right/up/down) between snapped windows using spatial overlap-based selection |
| 06 | `06_dim_inactive_windows` | Added CGS-based opacity dimming for non-focused managed windows with FocusObserver and WindowOpacityService |

---

## Important Files

`UnnamedWindowManager/ConfigData.swift`
`UnnamedWindowManager/Config.swift`
`UnnamedWindowManager/ConfigLoader.swift`
`UnnamedWindowManager/Services/KeybindingService.swift`
`UnnamedWindowManager/UnnamedWindowManagerApp.swift`
`UnnamedWindowManager/Services/FocusDirectionService.swift`
`UnnamedWindowManager/System/FocusLeftHandler.swift`
`UnnamedWindowManager/System/FocusRightHandler.swift`
`UnnamedWindowManager/System/FocusUpHandler.swift`
`UnnamedWindowManager/System/FocusDownHandler.swift`
`UnnamedWindowManager/System/WindowOpacityService.swift`
`UnnamedWindowManager/Observation/FocusObserver.swift`
`UnnamedWindowManager/System/UnsnapHandler.swift`
`UnnamedWindowManager/Observation/ResizeObserver.swift`

---
