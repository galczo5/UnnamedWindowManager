# Plan: 03_archived — [ARCHIVED] Multi-Root Spaces, Auto-Snap, Config File, and Shortcuts

> **Archived** — This entry consolidates plans [03 `03_multi_root`, 04 `04_menu_bar_organized_label`, 05 `05_auto_snap`, 06 `06_auto_organize`, 07 `07_unsnap_all`, 08 `08_yaml_config_file`, 09 `09_prune_stale_slots`, 10 `10_organize_shortcut`].
> These plans have been completed and their details removed. Only key context is preserved.

---

## What This Covered

The single-root tiling model was replaced with a multi-root system supporting independent tiling layouts per macOS Space, with automatic root creation/destruction based on CGWindowList visibility detection. On top of this, auto-snap and auto-organize observers were added to automatically tile windows on activation and creation, a "[organized]" label was added to the menu bar when a layout is active, and an "Unsnap all" action was introduced. Configuration was externalized from hardcoded constants to a user-editable `~/.config/unnamed/config.yml` file (backed by Yams), with menu items to open and reload the config. Stale slot pruning was added to handle terminal tab switches that leave ghost slots, and a global keyboard shortcut system (`KeybindingService`) was built for triggering Organize via a configurable hotkey.

---

## Plans Consolidated

| Original # | Name | Summary |
|---|---|---|
| 03 | `03_multi_root` | Replaced single `RootSlot` with `[UUID: RootSlot]` dictionary; added CGWindowList-based `visibleRootID()` for per-Space root routing; cross-root window migration on snap |
| 04 | `04_menu_bar_organized_label` | Added `isOrganized` state to `MenuState` and `[organized]` label in menu bar; reactive updates via `snapStateChanged` notification |
| 05 | `05_auto_snap` | Added `AutoSnapObserver` singleton with workspace activation and `kAXWindowCreatedNotification` observers to auto-snap windows when a layout is active |
| 06 | `06_auto_organize` | Extended auto-snap to bootstrap a layout on empty screens; `autoOrganize` config flag snaps the first window when no layout exists |
| 07 | `07_unsnap_all` | Added `removeVisibleRoot()` to `SnapService` and `unsnapAll()` to `UnsnapHandler`; menu item to clear all snapped windows at once |
| 08 | `08_yaml_config_file` | Created `ConfigData`, `ConfigLoader`, and rewrote `Config` as mutable singleton; YAML config at `~/.config/unnamed/config.yml` with open/reload menu items |
| 09 | `09_prune_stale_slots` | Added stale slot detection before auto-snap; prunes slots whose CGWindowID no longer exists in system window list (fixes terminal tab ghost slots) |
| 10 | `10_organize_shortcut` | Created `KeybindingService` with `NSEvent.addGlobalMonitorForEvents` for global hotkeys; configurable `shortcuts.organize` in config.yml |

---

## Important Files

`UnnamedWindowManager/Services/SharedRootStore.swift`
`UnnamedWindowManager/Services/SnapService.swift`
`UnnamedWindowManager/Services/KeybindingService.swift`
`UnnamedWindowManager/System/LayoutService.swift`
`UnnamedWindowManager/System/SnapHandler.swift`
`UnnamedWindowManager/System/OrganizeHandler.swift`
`UnnamedWindowManager/System/OrientFlipHandler.swift`
`UnnamedWindowManager/System/UnsnapHandler.swift`
`UnnamedWindowManager/System/WindowLister.swift`
`UnnamedWindowManager/System/ReapplyHandler.swift`
`UnnamedWindowManager/Observation/AutoSnapObserver.swift`
`UnnamedWindowManager/Config.swift`
`UnnamedWindowManager/ConfigData.swift`
`UnnamedWindowManager/ConfigLoader.swift`
`UnnamedWindowManager/UnnamedWindowManagerApp.swift`

---
