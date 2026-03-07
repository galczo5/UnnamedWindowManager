# Plan: 14_unsnap_all — Add "Unsnap all" menu item

## Checklist

- [x] Add `removeVisibleRoot() -> [WindowSlot]` to `SnapService`
- [x] Add `static func unsnapAll()` to `UnsnapHandler`
- [x] Add "Unsnap all" button in `UnnamedWindowManagerApp`

---

## Context / Problem

"Unsnap" (`UnsnapHandler.unsnap()`) only releases the frontmost focused window. There is no way to clear all snapped windows at once. The goal is a menu item "Unsnap all" that removes every window in the currently visible root in one action, restoring each window's pre-snap state and stopping AX observation.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/SnapService.swift` | Modify — add `removeVisibleRoot() -> [WindowSlot]` |
| `UnnamedWindowManager/System/UnsnapHandler.swift` | Modify — add `static func unsnapAll()` |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — add "Unsnap all" button after "Unsnap" |

---

## Implementation Steps

### 1. Add `removeVisibleRoot()` to `SnapService`

Atomically destroy the entire visible root and return the window slots it contained so the caller can clean up observers and visibility state.

```swift
func removeVisibleRoot() -> [WindowSlot] {
    store.queue.sync(flags: .barrier) {
        guard let id = visibleRootID() else { return [] }
        let leaves = tree.allLeaves(in: store.roots[id]!)
        store.roots.removeValue(forKey: id)
        store.windowCounts.removeValue(forKey: id)
        return leaves.compactMap { if case .window(let w) = $0 { return w } else { return nil } }
    }
}
```

### 2. Add `unsnapAll()` to `UnsnapHandler`

Calls `removeVisibleRoot()`, then for each returned slot: restores visibility and stops AX observation. Posts `snapStateChanged` so the menu bar label refreshes.

```swift
static func unsnapAll() {
    guard AXIsProcessTrusted() else { return }
    let removed = SnapService.shared.removeVisibleRoot()
    for key in removed {
        WindowVisibilityManager.shared.restoreAndForget(key)
        ResizeObserver.shared.stopObserving(key: key, pid: key.pid)
    }
    NotificationCenter.default.post(name: .snapStateChanged, object: nil)
}
```

### 3. Add menu button in `UnnamedWindowManagerApp`

Insert the new button directly after the existing "Unsnap" button:

```swift
Button("Unsnap")     { UnsnapHandler.unsnap()    }
Button("Unsnap all") { UnsnapHandler.unsnapAll() }
```

---

## Key Technical Notes

- `removeVisibleRoot()` uses a barrier sync so the root is fully gone before any observer teardown begins.
- No `ReapplyHandler.reapplyAll()` is needed — the layout is empty, nothing to reflow.
- `snapStateChanged` must be posted manually here because `ReapplyHandler` (which normally posts it) is not called.
- `NSScreen.main` is not needed for bulk removal — unlike single-window unsnap, no reflow occurs so no screen frame is required.

---

## Verification

1. Snap two or more windows → menu shows "Unsnap all"
2. Click "Unsnap all" → all windows are freed from the layout and return to their original sizes/positions
3. Menu bar icon reverts to the default (non-organized) state
4. Snap a single window, click "Unsnap all" → same result as clicking "Unsnap"
5. Click "Unsnap all" with no snapped windows → no crash, no visible change
