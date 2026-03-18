# Plan: 15_unsnap_on_minimize — Untile Window on Minimise or Fullscreen

## Checklist

- [x] Subscribe to `kAXWindowMiniaturizedNotification` in `ResizeObserver.observe()`
- [x] Unsubscribe in `ResizeObserver.stopObserving()`
- [x] Handle minimise notification in `ResizeObserver.handle()` — remove from layout and reflow
- [x] Handle fullscreen in `ResizeObserver.handle()` — detect via `kAXFullScreenAttribute` on resize notification

---

## Context / Problem

Two user actions cause a tiled window to leave the screen without triggering `AXUIElementDestroyed`:

1. **Minimise** (⌘M, Dock button, titlebar double-click) — window goes to the Dock; layout retains a ghost slot and does not redistribute the space.
2. **Fullscreen** (green button) — window moves to a new Space; layout retains a ghost slot.

The goal is to treat both as an immediate untile: remove the window from the layout and reflow remaining windows. No pre-tile position restore is needed — neither a minimised nor a fullscreen window returns to a floating desktop position.

If `autoSnap` is enabled, `AutoTileObserver` already handles re-tiling on app activation (triggered when the user restores or exits fullscreen), so no extra de-minimise / de-fullscreen path is required.

---

## macOS capability note

**Minimise:** `kAXWindowMiniaturizedNotification` fires on the main run loop when a window transitions into the minimised state.

**Fullscreen:** There is no dedicated fullscreen-entered AX notification. Instead, `kAXWindowResizedNotification` fires as the window grows. Immediately reading `kAXFullScreenAttribute` (`"AXFullScreen"`) from the element at that point returns `true` once the window has committed to fullscreen. Checking this attribute in the resize handler is the standard detection technique.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Observation/ResizeObserver.swift` | Modify — subscribe/unsubscribe to minimise notification; handle minimise and fullscreen |

---

## Implementation Steps

### 1. Subscribe and unsubscribe to minimise notification

In `observe(window:pid:key:)`, add alongside the existing notifications:

```swift
AXObserverAddNotification(axObs, window, kAXWindowMiniaturizedNotification as CFString, refcon)
```

In `stopObserving(key:pid:)`, remove it:

```swift
AXObserverRemoveNotification(axObs, window, kAXWindowMiniaturizedNotification as CFString)
```

### 2. Handle minimise and fullscreen in `handle(element:notification:pid:)`

`isScrolling` is already computed at the top of `handle()` — use it directly. Add two branches after the existing destroy check:

```swift
if notification == (kAXWindowMiniaturizedNotification as String) {
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

if notification == (kAXWindowResizedNotification as String) {
    var ref: CFTypeRef?
    let isFullScreen = AXUIElementCopyAttributeValue(element, kAXFullScreenAttribute as CFString, &ref) == .success
                       && (ref as? Bool) == true
    if isFullScreen {
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
}
```

`RestoreService.restore` is intentionally omitted in both paths — the window is leaving the desktop, not floating back to its pre-tile position.

`WindowVisibilityManager.windowRemoved` (not `restoreAndForget`) is used because neither state requires the WM to unminimise anything.

---

## Key Technical Notes

- `isScrolling` is computed once at the top of `handle()` before any branch — do not re-declare it inside the new branches.
- Both new branches must appear **after** the destroy check and **before** the `guard TileService.shared.isTracked(key) || isScrolling` line, so that keys in scrolling roots are handled correctly even when `TileService.isTracked` returns false.
- The fullscreen resize notification may fire before the window has fully transitioned; reading `kAXFullScreenAttribute` immediately is reliable because the attribute is set before the notification is delivered.
- Fullscreen windows move to a new Space and become off-screen; without this fix, `pruneOffScreenWindows` would eventually clean them up — but only on the next `reapplyAll`, leaving a ghost slot until then.
- If `autoSnap` is disabled, the window will not be re-tiled when the user returns from minimise/fullscreen. Manual re-tile is required — consistent with existing behaviour for newly opened windows.

---

## Verification

1. Tile two windows → minimise one via ⌘M → remaining window expands to fill screen.
2. Tile two windows → minimise one via Dock button → same result.
3. Un-minimise the window (with `autoSnap` on) → window is auto-tiled back into the layout.
4. Un-minimise the window (with `autoSnap` off) → window floats at its last position, no auto-tile.
5. Tile two windows → click green button on one → remaining window expands to fill screen.
6. Exit fullscreen (with `autoSnap` on) → window is auto-tiled back into the layout.
7. Tile a scrolling layout → minimise the center window → left stack promotes to center; reflow is correct.
8. Tile a scrolling layout → fullscreen the center window → same promotion behaviour.
9. Minimise/fullscreen the last window in a layout → layout root is destroyed; tiling state is cleared.
