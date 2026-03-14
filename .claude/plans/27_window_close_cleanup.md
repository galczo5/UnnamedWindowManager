# Plan: 27_window_close_cleanup — Remove Closed Windows from Tiling and Scrolling Roots

## Checklist

- [x] Handle scrolling root removal in `ResizeObserver.handle()` destroy path
- [x] Handle scrolling root pruning in `ReapplyHandler.pruneOffScreenWindows`

---

## Context / Problem

When a window is closed, `ResizeObserver.handle()` receives `kAXUIElementDestroyedNotification` and calls `TileService.shared.removeAndReflow` — but never `ScrollingTileService.shared.removeWindow`. Windows in a `ScrollingRootSlot` therefore linger in the tree after they close.

The same gap exists in the fallback prune path: `ReapplyHandler.pruneOffScreenWindows` iterates only `TileService.shared.leavesInVisibleRoot()`. If a scrolling window disappears without a destroy notification (e.g., moved to another Space), it is never pruned.

Both removal methods already exist and implement the correct promotion logic:
- `TileService.removeAndReflow` — removes leaf, destroys root if empty, recomputes sizes.
- `ScrollingTileService.removeWindow` — if center, promotes last child of left slot (or right if left empty); if left/right, removes from stack; destroys root if no windows remain.

The fix is to call the right method depending on which root type the window belongs to.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Observation/ResizeObserver.swift` | Modify — dispatch to scrolling removal in destroy notification handler |
| `UnnamedWindowManager/System/ReapplyHandler.swift` | Modify — prune closed scrolling windows alongside tiling windows |

---

## Implementation Steps

### 1. Dispatch to scrolling removal on window destroy

In `ResizeObserver.handle()` (line 66), `isScrolling` is already computed above. Use it to call the correct removal method:

```swift
if notification == kElementDestroyed as String {
    WindowOpacityService.shared.restore(hash: key.windowHash)
    if let screen = NSScreen.main {
        if isScrolling {
            ScrollingTileService.shared.removeWindow(key, screen: screen)
        } else {
            TileService.shared.removeAndReflow(key, screen: screen)
        }
    } else {
        TileService.shared.remove(key)
    }
    cleanup(key: key, pid: pid)
    WindowVisibilityManager.shared.windowRemoved(key)
    ReapplyHandler.reapplyAll()
    return
}
```

### 2. Prune closed scrolling windows in `pruneOffScreenWindows`

In `ReapplyHandler.pruneOffScreenWindows`, after the existing tiling prune loop, add a second loop for scrolling leaves:

```swift
let scrollingLeaves = ScrollingTileService.shared.leavesInVisibleScrollingRoot()
for leaf in scrollingLeaves {
    guard case .window(let w) = leaf else { continue }
    guard !onScreen.contains(w.windowHash) else { continue }
    Logger.shared.log("pruning off-screen scrolling window: pid=\(w.pid) hash=\(w.windowHash)")
    ResizeObserver.shared.stopObserving(key: w, pid: w.pid)
    ScrollingTileService.shared.removeWindow(w, screen: screen)
}
```

---

## Key Technical Notes

- `isScrolling` is already evaluated at the top of `ResizeObserver.handle()` before the notification type is checked — no extra tracking call needed.
- `ScrollingTileService.removeWindow` is already synchronized on `store.queue` barrier and handles root destruction when the last window is removed.
- The `else { TileService.shared.remove(key) }` fallback (no screen available) only covers the tiling case. Scrolling removal without a screen is a no-op — acceptable because `pruneOffScreenWindows` will catch it on the next `reapplyAll`.
- `pruneOffScreenWindows` calls `guard !onScreen.isEmpty else { return }` — this guard covers both loops, so the scrolling loop inherits the same early-exit.

---

## Verification

1. Tile 2 windows → close one → remaining window expands to fill the screen
2. Tile a window into scrolling layout (center + left stack) → close the center window → last item from left stack becomes new center; layout reapplies correctly
3. Scrolling layout with only 1 window → close it → scrolling root is destroyed, no orphan root in `SharedRootStore`
4. Scrolling layout with center + left stack → close a window from the left stack → center unchanged, stack shrinks; layout reapplies
5. Move a scrolling window to another Space → switch back → `pruneOffScreenWindows` removes it and reflows remaining windows
