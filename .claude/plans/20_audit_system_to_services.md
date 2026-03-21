# Plan: 20_audit_system_to_services — Move System/ into Services/ with subdirectory structure

## Checklist

- [x] Create subdirectory structure under Services/
- [x] Move Tiling/ files (TilingRootStore, TilingEditService, TilingSnapService, TilingNeighborService, TilingPositionService, TilingResizeService, TilingTreeQueryService, TilingTreeMutationService, TilingTreeInsertService, LayoutService)
- [x] Move Scrolling/ files (ScrollingTileService, ScrollingPositionService, ScrollingResizeService, ScrollingLayoutService, ScrollingFocusService)
- [x] Move Handlers/ files (FocusDown/Left/Right/Up, SwapDown/Left/Right/Up, TileHandler, TileAllHandler, UntileHandler, ScrollingRootHandler, ScrollOrganizeHandler, UnscrollHandler, OrientFlipHandler)
- [x] Move Navigation/ files (FocusDirectionService, SwapDirectionService)
- [x] Move Window/ files (AXHelpers, WindowLister, WindowOpacityService, OnScreenWindowCache, RestoreService)
- [x] Move root-level files (SharedRootStore, ReapplyHandler, KeybindingService, CommandService, NotificationService, ScreenHelper, SystemColor)
- [x] Delete empty System/ directory
- [x] Build to confirm no compiler errors

---

## Context / Problem

The project currently has two flat directories for service-layer code:

- `System/` — 25 files (handlers, layout services, AX helpers, utilities)
- `Services/` — 19 files (tiling tree services, scrolling services, keybinding, stores)

The split is historical and doesn't reflect a clear architectural boundary. Both directories contain services, handlers, and utilities. The goal is to **merge everything into `Services/`** with a clean subdirectory structure that groups files by domain.

The project uses `PBXFileSystemSynchronizedRootGroup` in the Xcode project, so the filesystem IS the project structure — no pbxproj edits needed.

---

## Code quality findings

### ScrollingTileService.swift (350 lines)
- `scrollLeft()` and `scrollRight()` share ~90% of their logic (mirror image). **[needs decision]** — could extract a shared `scroll(from:to:)` helper, but the mirrored logic is clear as-is.
- `removeWindow()` has three near-identical stacking-slot removal blocks (center/left/right). Could extract a helper but the branches differ in promotion logic.

### KeybindingService.swift (280 lines)
- At the boundary but not over 300. The `installEventTap()` callback is long but hard to split due to the C-callback requirement. No action needed.

### ReapplyHandler.swift (157 lines)
- `reapplyAll()` has nested `asyncAfter` chains (3 levels deep). Functional and clear enough given the timing requirements. No action needed.

### Thin handlers (FocusDown/Up, SwapDown/Left/Right/Up — 6 lines each)
- These are one-liner delegations. They exist to give KeybindingService clean call sites. No consolidation needed.

---

## Target directory structure

```
Services/
├── Tiling/                    # Tiling slot tree and layout
│   ├── TilingRootStore.swift
│   ├── TilingEditService.swift
│   ├── TilingSnapService.swift
│   ├── TilingNeighborService.swift
│   ├── TilingPositionService.swift
│   ├── TilingResizeService.swift
│   ├── TilingTreeQueryService.swift
│   ├── TilingTreeMutationService.swift
│   ├── TilingTreeInsertService.swift
│   └── LayoutService.swift
├── Scrolling/                 # Scrolling layout and operations
│   ├── ScrollingTileService.swift
│   ├── ScrollingPositionService.swift
│   ├── ScrollingResizeService.swift
│   ├── ScrollingLayoutService.swift
│   └── ScrollingFocusService.swift
├── Handlers/                  # User action entry points (keyboard shortcuts)
│   ├── FocusDownHandler.swift
│   ├── FocusLeftHandler.swift
│   ├── FocusRightHandler.swift
│   ├── FocusUpHandler.swift
│   ├── SwapDownHandler.swift
│   ├── SwapLeftHandler.swift
│   ├── SwapRightHandler.swift
│   ├── SwapUpHandler.swift
│   ├── TileHandler.swift
│   ├── TileAllHandler.swift
│   ├── UntileHandler.swift
│   ├── ScrollingRootHandler.swift
│   ├── ScrollOrganizeHandler.swift
│   ├── UnscrollHandler.swift
│   └── OrientFlipHandler.swift
├── Navigation/                # Cross-layout directional services
│   ├── FocusDirectionService.swift
│   └── SwapDirectionService.swift
├── Window/                    # Window utilities and AX helpers
│   ├── AXHelpers.swift
│   ├── WindowLister.swift
│   ├── WindowOpacityService.swift
│   ├── OnScreenWindowCache.swift
│   └── RestoreService.swift
├── SharedRootStore.swift      # Thread-safe root storage (used by Tiling + Scrolling)
├── ReapplyHandler.swift       # Layout reapplication orchestrator
├── KeybindingService.swift    # Global shortcut registration
├── CommandService.swift       # Shell command execution
├── NotificationService.swift  # User notifications
├── ScreenHelper.swift         # Screen geometry
└── SystemColor.swift          # Config color resolution
```

---

## Files to create / modify

| File | Action |
|------|--------|
| `Services/Tiling/` | **New directory** |
| `Services/Scrolling/` | **New directory** |
| `Services/Handlers/` | **New directory** |
| `Services/Navigation/` | **New directory** |
| `Services/Window/` | **New directory** |
| 10 files → `Services/Tiling/` | Move from Services/ root and System/ |
| 5 files → `Services/Scrolling/` | Move from Services/ root and System/ |
| 15 files → `Services/Handlers/` | Move from System/ |
| 2 files → `Services/Navigation/` | Move from Services/ root |
| 5 files → `Services/Window/` | Move from System/ |
| 7 files stay at `Services/` root | Move from System/ (ReapplyHandler, ScreenHelper, SystemColor) + keep existing (SharedRootStore, KeybindingService, CommandService, NotificationService) |
| `System/` | **Delete directory** (empty after moves) |

---

## Implementation Steps

### 1. Create subdirectories

Create `Tiling/`, `Scrolling/`, `Handlers/`, `Navigation/`, `Window/` under `Services/`.

### 2. Move Tiling files

From `Services/` root → `Services/Tiling/`:
- TilingRootStore.swift, TilingEditService.swift, TilingSnapService.swift, TilingNeighborService.swift, TilingPositionService.swift, TilingResizeService.swift, TilingTreeQueryService.swift, TilingTreeMutationService.swift, TilingTreeInsertService.swift

From `System/` → `Services/Tiling/`:
- LayoutService.swift

### 3. Move Scrolling files

From `Services/` root → `Services/Scrolling/`:
- ScrollingTileService.swift, ScrollingPositionService.swift, ScrollingResizeService.swift

From `System/` → `Services/Scrolling/`:
- ScrollingLayoutService.swift, ScrollingFocusService.swift

### 4. Move Handler files

From `System/` → `Services/Handlers/`:
- FocusDownHandler.swift, FocusLeftHandler.swift, FocusRightHandler.swift, FocusUpHandler.swift
- SwapDownHandler.swift, SwapLeftHandler.swift, SwapRightHandler.swift, SwapUpHandler.swift
- TileHandler.swift, TileAllHandler.swift, UntileHandler.swift
- ScrollingRootHandler.swift, ScrollOrganizeHandler.swift, UnscrollHandler.swift
- OrientFlipHandler.swift

### 5. Move Navigation files

From `Services/` root → `Services/Navigation/`:
- FocusDirectionService.swift, SwapDirectionService.swift

### 6. Move Window files

From `System/` → `Services/Window/`:
- AXHelpers.swift, WindowLister.swift, OnScreenWindowCache.swift, RestoreService.swift

From `Services/` root → `Services/Window/`:
- WindowOpacityService.swift

### 7. Move remaining System files to Services root

From `System/` → `Services/`:
- ReapplyHandler.swift, ScreenHelper.swift, SystemColor.swift

(SharedRootStore, KeybindingService, CommandService, NotificationService already at Services/ root.)

### 8. Delete System directory

Remove the now-empty `System/` directory.

### 9. Build

Run `./build.sh` to confirm no compiler errors.

---

## Key Technical Notes

- The project uses `PBXFileSystemSynchronizedRootGroup` — Xcode auto-syncs with the filesystem. No pbxproj edits needed.
- No Swift `import` statements reference file paths, only module names and type names. Moving files within the same target has zero impact on compilation.
- LayoutService goes in Tiling/ because it walks the tiling slot tree and applies tiling layout via AX. ScrollingLayoutService goes in Scrolling/ for the same reason.
- ReapplyHandler stays at Services/ root because it orchestrates across both Tiling and Scrolling — it doesn't belong to either subdomain.

---

## Verification

1. Build with `./build.sh` — compiles with zero errors
2. Open Xcode — file navigator shows the new subdirectory structure under Services/
3. System/ directory no longer exists
4. All 44 files accounted for in their new locations
