# Plan: 16_untile_persistent_refusals — Untile windows that refuse resize twice across three passes

## Checklist

- [x] Add a third validation pass in `ReapplyHandler.reapplyAll()`
- [x] Track per-window refusal counts across passes in `PostResizeValidator`
- [x] Add `untileByKey` method to `UntileHandler` for programmatic untiling
- [x] Untile and notify for windows that refused twice out of three passes

---

## Context / Problem

Currently, `ReapplyHandler.reapplyAll()` applies the layout (pass 1) and then runs `PostResizeValidator.checkAndFixRefusals()` at +0.3s (pass 2). The second pass detects windows that refused the target size, resizes the layout tree to accommodate them, and posts a notification — but the window stays tiled.

Some windows persistently refuse to resize (e.g., apps with hard minimum sizes). These windows should be automatically untiled to stop them from breaking the layout.

**Goal:** Add a third validation pass. If a window refused in both pass 2 and pass 3 (i.e., it refused twice), untile it and show a notification.

---

## Behaviour spec

1. Pass 1 (existing, +10ms debounce): Apply layout to all windows.
2. Pass 2 (existing, +0.3s): `checkAndFixRefusals` detects refusals, resizes the tree to accommodate, reapplies layout. Returns the set of refusing `WindowSlot`s.
3. Pass 3 (new, +0.6s): `checkAndFixRefusals` runs again. Any window that refused in **both** pass 2 and pass 3 is untiled and a notification is posted.

A window that refused in pass 2 but complied in pass 3 stays tiled — the tree resize fixed it. Only persistent refusals (2 out of 2 checks) trigger untiling.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Observation/PostResizeValidator.swift` | Modify — split detection from action; return refusing keys |
| `UnnamedWindowManager/System/ReapplyHandler.swift` | Modify — add third pass; track refusal counts; trigger untile |
| `UnnamedWindowManager/System/UntileHandler.swift` | Modify — add `untileByKey(_:screen:)` for programmatic untiling |

---

## Implementation Steps

### 1. Make `checkAndFixRefusals` return refusing keys

Change `PostResizeValidator.checkAndFixRefusals` to return `Set<WindowSlot>` — the set of windows that refused. Move the notification posting out; the caller will decide what to do based on pass results.

```swift
@discardableResult
static func checkAndFixRefusals(windows: Set<WindowSlot>, screen: NSScreen) -> Set<WindowSlot> {
    // ... existing detection logic ...

    guard !refusals.isEmpty else {
        Logger.shared.log("checkAndFixRefusals: no refusals, skipping")
        return []
    }

    // ... existing resize + reapply logic ...

    return Set(refusals.map(\.key))
}
```

Remove the notification posting from inside this method — it moves to the caller.

### 2. Add `untileByKey` to `UntileHandler`

Add a method that untiles a specific window by its `WindowSlot`, without requiring it to be the focused window:

```swift
static func untileByKey(_ key: WindowSlot, screen: NSScreen) {
    let isScrolling = ScrollingTileService.shared.isTracked(key)
    WindowOpacityService.shared.restore(hash: key.windowHash)
    WindowVisibilityManager.shared.restoreAndForget(key)
    if let ax = ResizeObserver.shared.elements[key] {
        RestoreService.restore(key, element: ax)
    }
    if isScrolling {
        ScrollingTileService.shared.removeWindow(key, screen: screen)
    } else {
        TileService.shared.removeAndReflow(key, screen: screen)
    }
    ResizeObserver.shared.stopObserving(key: key, pid: key.pid)
}
```

### 3. Add third pass and untile logic in `ReapplyHandler.reapplyAll()`

After the existing pass 2 at +0.3s, schedule pass 3 at +0.6s. Use the return value from pass 2 to know which windows refused, and compare with pass 3 results:

```swift
// Pass 2 (existing, modified)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    guard let screen = NSScreen.main else { return }
    let pass2Refusals = PostResizeValidator.checkAndFixRefusals(windows: allWindows, screen: screen)

    guard !pass2Refusals.isEmpty else { return }

    // Notify for pass-2 refusals (these got accommodated)
    for key in pass2Refusals {
        let appName = NSRunningApplication(processIdentifier: key.pid)?.localizedName ?? "Unknown"
        NotificationService.shared.post(
            title: "Window refused to resize",
            body: "\(appName) could not be resized to fit its slot."
        )
    }

    // Pass 3 — check if the same windows still refuse after tree adjustment
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        guard let screen = NSScreen.main else { return }
        let pass3Refusals = PostResizeValidator.checkAndFixRefusals(windows: allWindows, screen: screen)

        let persistentRefusals = pass2Refusals.intersection(pass3Refusals)
        guard !persistentRefusals.isEmpty else { return }

        for key in persistentRefusals {
            UntileHandler.untileByKey(key, screen: screen)
            let appName = NSRunningApplication(processIdentifier: key.pid)?.localizedName ?? "Unknown"
            NotificationService.shared.post(
                title: "Window untiled",
                body: "\(appName) was untiled because it repeatedly refused to resize."
            )
        }
        ReapplyHandler.reapplyAll()
    }
}
```

---

## Key Technical Notes

- Pass 3 is only scheduled if pass 2 found refusals — no unnecessary work when all windows comply.
- The +0.3s spacing between passes is consistent with the existing delay that lets windows settle after AX repositioning.
- `checkAndFixRefusals` still resizes the tree on pass 3 for windows that refused only once (new in pass 3 but not in pass 2). These are accommodated, not untiled.
- The `ReapplyHandler.reapplyAll()` call after untiling persistent refusals reflows the remaining windows. This will not cause infinite recursion because the refusing windows have been removed.
- `untileByKey` restores opacity, visibility, and pre-tile frame before removing from the tree, matching the cleanup sequence used in `ResizeObserver`'s destroy handler.
- Scrolling-layout windows are handled via `ScrollingTileService.shared.removeWindow` in `untileByKey`.

---

## Verification

1. Tile a window that has a hard minimum size (e.g., System Settings) into a slot smaller than its minimum → it gets accommodated in pass 2, notification appears
2. Tile a window that persistently refuses (minimum size exceeds any slot) → after pass 3 it gets untiled, "Window untiled" notification appears
3. Tile normal windows that comply → no extra passes fire, no notifications
4. Verify the untiled window's frame is restored to its pre-tile position
5. Verify remaining tiled windows reflow correctly after the persistent refusal is untiled
