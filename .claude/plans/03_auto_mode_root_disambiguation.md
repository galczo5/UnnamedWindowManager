# Plan: 03_auto_mode_root_disambiguation — Fix new windows snapping to wrong root type

## Checklist

- [ ] Add `ActiveRootType` enum and tracker to `SharedRootStore`
- [ ] Update `SpaceChangeObserver` to set the active root type on space change
- [ ] Update `AutoModeHandler.snap()` to use active root type for disambiguation

---

## Context / Problem

When the active desktop has a **scrolling** root and a new window appears (e.g. Xcode opens `config.yml`), `AutoModeHandler.snap()` incorrectly assigns it to the **tiling** root on a different space.

**Root cause**: `AutoModeHandler.snap()` checks `snapshotVisibleRoot()` before `snapshotVisibleScrollingRoot()`. Both use `OnScreenWindowCache.visibleHashes()`, which queries `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`. macOS sometimes reports windows from a non-active space as "on screen" — for example, when an app (Xcode) has windows on multiple spaces and a new window opens. This makes `snapshotVisibleRoot()` return non-nil even though the tiling root's space is not the active one.

The current priority order (tiling first, scrolling second) means tiling always wins the race, producing the bug.

**Goal**: When both a tiling root and a scrolling root appear visible, snap the new window into whichever root type is actually active on the current space.

---

## macOS visibility caveat

`CGWindowListCopyWindowInfo(.optionOnScreenOnly)` can include windows from inactive spaces when an app has windows across multiple spaces. There is no public API to query which macOS Space a window belongs to. The only reliable signal is **which root type was detected as active during the most recent space change**.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/SharedRootStore.swift` | Modify — add `ActiveRootType` enum and `activeRootType` property |
| `UnnamedWindowManager/Services/Observation/SpaceChangeObserver.swift` | Modify — set `activeRootType` after visibility checks |
| `UnnamedWindowManager/Services/AutoMode/AutoModeHandler.swift` | Modify — use `activeRootType` to disambiguate when both roots are visible |

---

## Implementation Steps

### 1. Add `ActiveRootType` to `SharedRootStore`

Add an enum and a property to track which root type is currently the primary one on the active space.

```swift
enum ActiveRootType {
    case tiling
    case scrolling
}
```

Add to `SharedRootStore`:

```swift
/// The root type most recently determined to be active on the current space.
/// Updated by SpaceChangeObserver on each space switch.
private(set) var activeRootType: ActiveRootType?

func setActiveRootType(_ type: ActiveRootType?) {
    queue.async(flags: .barrier) { [self] in
        activeRootType = type
    }
}
```

### 2. Update `SpaceChangeObserver` to set active root type

After the existing visibility checks in `activeSpaceDidChange()`, determine the active root type and store it. The logic:

- If only tiling is visible → `.tiling`
- If only scrolling is visible → `.scrolling`
- If both are visible → pick the **opposite** of the previous active type (a space switch to a space with the same root type is unusual; the user likely switched TO the other type). If no previous type, fall back to whichever root changed (was not already the `last*RootID`).
- If neither is visible → `nil`

```swift
// After existing tiling/scrolling visibility checks:
let tilingVisible = TilingRootStore.shared.snapshotVisibleRoot() != nil
let scrollingVisible = ScrollingRootStore.shared.snapshotVisibleScrollingRoot() != nil

let newType: ActiveRootType?
if tilingVisible && scrollingVisible {
    // Both visible — user likely switched to the opposite of the previous active type
    if SharedRootStore.shared.activeRootType == .tiling {
        newType = .scrolling
    } else {
        newType = .tiling
    }
} else if tilingVisible {
    newType = .tiling
} else if scrollingVisible {
    newType = .scrolling
} else {
    newType = nil
}
SharedRootStore.shared.setActiveRootType(newType)
```

Note: `snapshotVisibleRoot()` and `snapshotVisibleScrollingRoot()` are already called above in the method. Reuse their results (store them in locals) instead of calling them again.

### 3. Update `AutoModeHandler.snap()` to use active root type

Replace the current tiling-first check:

```swift
// Before (tiling always wins):
if TilingRootStore.shared.snapshotVisibleRoot() != nil {
    TileHandler.tileLeft(window: window, pid: pid)
} else if ScrollingRootStore.shared.snapshotVisibleScrollingRoot() != nil {
    ScrollHandler.scrollWindow(window, pid: pid)
} else {
    return
}
```

With disambiguation logic:

```swift
let tilingRoot = TilingRootStore.shared.snapshotVisibleRoot()
let scrollingRoot = ScrollingRootStore.shared.snapshotVisibleScrollingRoot()

if tilingRoot != nil && scrollingRoot != nil {
    // Both visible — use the tracked active root type to break the tie
    switch SharedRootStore.shared.activeRootType {
    case .scrolling:
        ScrollHandler.scrollWindow(window, pid: pid)
    default:
        TileHandler.tileLeft(window: window, pid: pid)
    }
} else if tilingRoot != nil {
    TileHandler.tileLeft(window: window, pid: pid)
} else if scrollingRoot != nil {
    ScrollHandler.scrollWindow(window, pid: pid)
} else {
    return
}
```

The `activeRootType` read does not need to go through the queue because it is only read on the main thread and written via `async(flags: .barrier)` — by the time `snap()` runs (dispatched to main), the barrier write from `SpaceChangeObserver` has completed.

---

## Key Technical Notes

- `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` is unreliable for per-space filtering; it may include windows from inactive spaces for multi-space apps.
- `SpaceChangeObserver.activeSpaceDidChange()` is the only reliable point to determine the active space's root type, since it fires immediately after macOS commits the space switch.
- The "opposite of previous" heuristic when both are visible works because: (a) you cannot have tiling and scrolling on the same space, and (b) a space switch implies moving to a different space, thus a different root type.
- `activeRootType` must be `nil`-able for the case where the user switches to a space with no managed root.
- The `activeRootType` property should be readable without taking the queue lock from the main thread for simplicity; use `async(flags: .barrier)` for writes only. Reads on the main thread are safe because writes complete before the next main-thread run loop cycle.

---

## Verification

1. Set up two spaces: one with a tiling root (2 windows), one with a scrolling root (2 windows)
2. Switch to the scrolling space
3. Open a new window (e.g. open a file in Xcode) → it should be added to the scrolling root, not the tiling root
4. Switch to the tiling space → open a new window → it should be added to the tiling root
5. Check logs: `window appeared` should show the correct root assignment
6. Verify that `logRootChanged` no longer shows a WARNING about multiple roots being visible (unless both truly are on the same space)
7. Switch rapidly between spaces and open windows — no incorrect root assignment
