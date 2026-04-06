# Plan: 09_simplify_root_services — Simplify store/service layer after method migration

## Checklist

- [x] Audit `TilingEditService` — verify all methods are thin store wrappers
- [x] Audit `TilingSnapService` — verify all methods are thin store wrappers
- [x] Audit `ScrollingRootStore` — verify all methods are thin store wrappers
- [x] Merge `TilingEditService` into `TilingSnapService` (or vice versa) if both are now thin wrappers
- [x] Move `TilingRootStore` query methods onto `SharedRootStore` or inline where trivial
- [x] Remove any redundant intermediate service layers
- [x] Update `CODE.md` to reflect new `Model/TilingRoot/` and `Model/ScrollingRoot/` directories
- [x] Final grep cleanup — no references to deleted types remain
- [ ] Verify build and all functionality

---

## Context / Problem

After stages 7 and 8, `TilingEditService`, `TilingSnapService`, and `ScrollingRootStore` are reduced to thin wrappers that:
1. Acquire the store lock (barrier block)
2. Look up the right root by visibility or key containment
3. Call one or two methods on the root struct
4. Write the root back to the store
5. Log

Many of these methods are nearly identical in structure. This stage audits whether any services can be merged, simplified, or eliminated now that the real logic lives on the struct.

---

## Files to modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/Tiling/TilingEditService.swift` | Audit — consider merging with TilingSnapService |
| `UnnamedWindowManager/Services/Tiling/TilingSnapService.swift` | Audit — consider absorbing TilingEditService |
| `UnnamedWindowManager/Services/Tiling/TilingRootStore.swift` | Audit — simplify query delegation |
| `UnnamedWindowManager/Services/Scrolling/ScrollingRootStore.swift` | Audit — verify thin wrapper status |
| `UnnamedWindowManager/Services/Scrolling/ScrollingResizeService.swift` | Consider deleting — may be a one-line wrapper |
| `UnnamedWindowManager/Services/Scrolling/ScrollingFocusService.swift` | Consider deleting — may be a thin wrapper |
| `UnnamedWindowManager/UnnamedWindowManager/CODE.md` | Update directory structure documentation |

---

## Implementation Steps

### 1. Evaluate TilingEditService + TilingSnapService merge

After stage 7, both classes do the same thing: acquire lock → find root → call root method → write back. The original split was:
- `TilingSnapService` — add/remove windows (snap, remove, removeAndReflow, removeVisibleRoot, removeAllTilingRoots, consolidateVisibleRoots)
- `TilingEditService` — modify existing layout (resize, swap, flipParentOrientation, insertAdjacent, recomputeVisibleRootSizes)

With the tree logic on the struct, both are just "tiling store operations". Consider merging into a single `TilingService` (or keep separate if the file would be too large). The decision depends on line count after simplification.

If after stage 7 each method is ~10 lines (lock + lookup + root.method() + writeback + log), then:
- `TilingSnapService`: 6 methods × ~10 lines = ~60 lines
- `TilingEditService`: 5 methods × ~10 lines = ~50 lines
- Merged: ~110 lines — small enough for one file

### 2. Evaluate ScrollingResizeService and ScrollingFocusService

After stage 8:

`ScrollingResizeService.applyResize()` currently delegates to `ScrollingRootStore.updateCenterFraction()`. It may be a one-method wrapper that can be inlined at call sites.

`ScrollingFocusService` has three methods that delegate to `ScrollingRootStore`:
- `scrollLeft()` → `ScrollingRootStore.shared.scrollLeft(screen:)`
- `scrollRight()` → `ScrollingRootStore.shared.scrollRight(screen:)`
- `scrollToCenter(key:)` → `ScrollingRootStore.shared.scrollToWindow(key, screen:)`

If these are 1:1 delegations with no added logic, delete the service and call `ScrollingRootStore` directly from the handler layer.

### 3. Simplify TilingRootStore queries

`TilingRootStore` has query methods that delegate to `root.isTracked()`, `root.allLeaves()`, etc. with store lock. Some of these (like `isTracked`, `rootID(containing:)`) are used frequently and justify their existence. Others may now be redundant. Audit each method:

- `isTracked(_:)` — keep (used by many callers who don't need the lock details)
- `leavesInVisibleRoot()` — keep (convenience)
- `snapshotVisibleRoot()` — keep (returns copy, important for thread safety)
- `storedSlot(_:)` — keep
- `parentOrientation(of:)` — keep
- `rootID(containing:)` / `rootIDSync(containing:)` — keep (lock management)
- `visibleRootID()` — keep (visibility check)

Likely all stay — the store is a clean abstraction for thread-safe access.

### 4. Update CODE.md

Document the new directory structure:
```
Model/
├── TilingRoot/
│   ├── TilingRootSlot.swift         # Tiling tree: struct + all query/mutation/sizing methods
│   └── TilingSlotRecursion.swift    # Recursive Slot-level helpers for tree operations
├── ScrollingRoot/
│   ├── ScrollingRootSlot.swift      # Scrolling root: struct + all operations
│   └── ScrollingSlotLocation.swift  # Center/left/right location enum
├── WindowSlot.swift
├── Slot.swift
├── RootSlot.swift
├── SplitSlot.swift
├── StackingSlot.swift
├── Orientation.swift
├── StackingAlign.swift
└── DropTarget.swift
```

---

## Key Technical Notes

- This stage is primarily an audit and cleanup — no new functionality. The app should behave identically before and after.
- If `TilingEditService` and `TilingSnapService` merge, choose a name that reflects both roles: `TilingStoreService`, `TilingOperations`, or simply `TilingService`.
- Deleting wrapper services (`ScrollingResizeService`, `ScrollingFocusService`) requires updating their callers. Grep for all references before deleting.
- Keep `ScrollingRootStore` even if thin — it owns `visibleScrollingRootID()` and the barrier block pattern. Scrolling operations still need thread-safe store access.

---

## Verification

1. Build — no errors
2. Full regression: tile, untile, scroll, unscroll, resize, swap, flip, focus navigation, drag-and-drop, Mission Control space changes, multi-monitor
3. `CODE.md` matches actual directory structure
4. No orphaned files (services that are never referenced)
5. Grep for deleted type names — zero matches
