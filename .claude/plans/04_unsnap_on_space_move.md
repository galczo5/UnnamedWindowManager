# Plan: 04_unsnap_on_space_move — Untile window when moved to another Space

## Checklist

- [x] Replace manual cleanup in `pruneOffScreenWindows` (tiling branch) with `UntileHandler.untileByKey`
- [x] Replace manual cleanup in `pruneOffScreenWindows` (scrolling branch) with `UntileHandler.untileByKey`

---

## Context / Problem

When a user drags a tiled/scrolled window from one macOS Space to another (via Mission Control or
the "Move to Desktop N" context menu), the window keeps its tiled frame on the destination space.
The tiling manager strips it from the source-space layout but does not restore its pre-tile
size/origin, leaving it at an awkward position.

**Root cause**: `ReapplyHandler.pruneOffScreenWindows` removes windows whose CGWindowID disappears
from the current space's on-screen list. The prune code does a minimal cleanup
(`stopObserving + removeAndReflow`), skipping the full untile path that calls
`RestoreService.restore` (which resets size/origin to the pre-tile frame via the AX API).

**Goal**: Any tracked window that moves to a different Space should be fully untiled — opacity,
visibility tracking, and pre-tile frame all restored — on whichever space it lands on.

---

## macOS capability note

`RestoreService.restore` calls `AnimationService.shared.animate`, which uses the Accessibility API
(`AXUIElementSetAttributeValue` for position/size). The AX API can set attributes on windows
regardless of which Space they currently occupy, so restoring a window's pre-tile frame while it is
on a non-active Space works correctly.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/ReapplyHandler.swift` | Modify — replace manual prune cleanup with `UntileHandler.untileByKey` |

---

## Implementation Steps

### 1. Replace the manual prune with `UntileHandler.untileByKey`

In `pruneOffScreenWindows` (lines ~131–187 of `ReapplyHandler.swift`), both the tiling and scrolling
branches end with a manual two-call cleanup after the tab-swap check fails. Replace each with the
existing `untileByKey` helper, which performs the full teardown including `RestoreService.restore`.

**Tiling branch** — replace:

```swift
ResizeObserver.shared.stopObserving(key: w, pid: w.pid)
TilingSnapService.shared.removeAndReflow(w, screen: screen)
```

with:

```swift
UntileHandler.untileByKey(w, screen: screen)
```

**Scrolling branch** — replace:

```swift
ResizeObserver.shared.stopObserving(key: w, pid: w.pid)
ScrollingRootStore.shared.removeWindow(w, screen: screen)
```

with:

```swift
UntileHandler.untileByKey(w, screen: screen)
```

`UntileHandler.untileByKey` already handles the `isScrolling` check internally, so one call covers
both layout types.

---

## Key Technical Notes

- `pruneOffScreenWindows` is called from `reapplyAll()`; do NOT call `reapplyAll()` inside the
  prune loop — `untileByKey` does not do so and that is intentional.
- The tab-swap detection block (`didSwap`) runs before the prune cleanup and continues the loop
  when a swap is detected. The change only affects the `!didSwap` path — tab behaviour is untouched.
- `UntileHandler.untileByKey` checks `ScrollingRootStore.shared.isTracked(key)` internally to pick
  the right removal path, so the scrolling branch can use the same call as the tiling branch.
- AX position/size writes on off-screen windows may be invisible until the user switches to that
  Space — this is expected and correct behaviour.

---

## Verification

1. Tile two windows on Space 1 → both snap to tiling layout.
2. Open Mission Control, drag one window to Space 2.
3. Switch to Space 2 → the dragged window should appear at its original (pre-tile) size and position, not at the tiled frame.
4. Switch back to Space 1 → remaining window reflowed correctly, no crash.
5. Repeat with a scrolling layout (scroll two windows, move one to another space).
6. Move a window to another space using "Move to Desktop N" context menu → same untile behaviour.
7. Switch tabs in a tabbed tiled window, then move to another space → no crash, tab group untiled cleanly.
