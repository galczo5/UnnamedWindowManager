# Plan: 13_auto_organize — Snap the first window on an empty screen

## Checklist

- [x] Add `autoOrganize: Bool` to `Config.swift`
- [x] Modify `AutoSnapObserver.snapFocusedWindow` to handle `autoOrganize` case
- [x] Update `UnnamedWindowManagerApp.init()` to start observer when `autoOrganize` is true

---

## Context / Problem

`autoSnap` snaps incoming windows only when a layout is **already active** on screen — it can't
bootstrap a layout from nothing. `autoOrganize` covers the complementary case: when the screen is
**empty** (no snapped windows), snap the very first window that appears. Once a layout exists,
`autoOrganize` is silent and lets the user (or `autoSnap`) manage subsequent windows.

Current behaviour: first window on an empty screen is never auto-snapped.
Goal: when `Config.autoOrganize == true` and no layout is visible on screen, auto-snap any window
that comes to the foreground or is freshly created.

---

## Behaviour spec

- `Config.autoOrganize = true` by default.
- Trigger paths (same as `autoSnap`):
  1. **App activation** (`NSWorkspace.didActivateApplicationNotification`) — snap the newly active
     app's focused window if no layout exists.
  2. **Window created** (`kAXWindowCreatedNotification`) — snap the focused window of the app that
     opened a new window if no layout exists.
- **Precondition**: both paths are no-ops unless `SnapService.shared.snapshotVisibleRoot() == nil`,
  i.e. the screen has no snapped windows. Once the first window is snapped a layout exists, so
  subsequent `autoOrganize` checks become no-ops.
- If both `autoSnap` and `autoOrganize` are true they complement each other: `autoOrganize`
  bootstraps the layout for the first window; `autoSnap` takes over for subsequent windows.
- The `AutoSnapObserver` singleton is shared; it is started if either flag is true.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Config.swift` | Modify — add `static let autoOrganize: Bool = true` |
| `UnnamedWindowManager/Observation/AutoSnapObserver.swift` | Modify — handle `autoOrganize` in `snapFocusedWindow` |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — start observer when `autoOrganize` is true |

---

## Implementation Steps

### 1. Add `autoOrganize` to Config

```swift
/// When true, automatically snap the first window on an empty screen (no existing layout).
/// Complements autoSnap: autoOrganize handles the empty-screen case; autoSnap handles
/// subsequent windows once a layout exists.
static let autoOrganize: Bool = true
```

### 2. Extend `AutoSnapObserver.snapFocusedWindow`

The current method guards on `snapshotVisibleRoot() != nil` (layout exists → autoSnap proceeds).
Add an `autoOrganize` branch for the inverse case:

```swift
private func snapFocusedWindow(pid: pid_t) {
    let hasLayout = SnapService.shared.snapshotVisibleRoot() != nil
    if Config.autoSnap && hasLayout {
        // fall through to snap below
    } else if Config.autoOrganize && !hasLayout {
        // fall through to snap below
    } else {
        return
    }
    let axApp = AXUIElementCreateApplication(pid)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success
    else { return }
    SnapHandler.snapLeft(window: ref as! AXUIElement, pid: pid)
}
```

### 3. Start the observer for `autoOrganize` in `UnnamedWindowManagerApp.init()`

Change the existing guard from `Config.autoSnap` to `Config.autoSnap || Config.autoOrganize`:

```swift
if Config.autoSnap || Config.autoOrganize {
    AutoSnapObserver.shared.start()
}
```

---

## Key Technical Notes

- `snapshotVisibleRoot()` returns `nil` when no tracked window is currently on screen — exactly
  the "empty screen" signal needed as the `autoOrganize` precondition.
- After `SnapHandler.snapLeft` runs for the first window, `snapshotVisibleRoot()` will return
  non-nil, so subsequent `autoOrganize` checks immediately become no-ops without extra state.
- `autoSnap` and `autoOrganize` guards are mutually exclusive per call (`hasLayout` vs
  `!hasLayout`), so both can be enabled simultaneously without double-snapping.
- `SnapHandler.snapLeft` is idempotent — safe to call even if the window turns out to be already
  tracked or ineligible (minimised, too small).
- The observer is already shared (`AutoSnapObserver.shared`); no new singleton or file is needed.

---

## Verification

1. Set `Config.autoOrganize = true`, `Config.autoSnap = false`, build and run.
2. Ensure no windows are snapped (fresh launch). Open TextEdit → its window snaps automatically.
3. Open a second app while TextEdit is snapped → second window does **not** auto-snap
   (screen is not empty; `autoOrganize` is silent).
4. Unsnap all windows so the layout is empty. Switch to Safari → Safari's window snaps.
5. Set `Config.autoOrganize = false`, rebuild → first window on empty screen is never auto-snapped;
   manual Snap still works.
6. Set both `autoOrganize = true` and `autoSnap = true`: first window snaps (autoOrganize);
   subsequent app switches also snap (autoSnap).
