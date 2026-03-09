# Plan: 18_reapply_debounce — Debounce layout reapplication and fix validator timing

## Checklist

- [ ] Add 100ms debounce to `ReapplyHandler.reapplyAll()` with internal `pendingLayout` work item
- [ ] Move `reapplying` guard management inside the debounced execution block
- [ ] Move `PostResizeValidator.checkAndFixRefusals` scheduling inside the debounced execution block
- [ ] Remove redundant `reapplying` set/clear from `ResizeObserver.scheduleReapplyWhenMouseUp`
- [ ] Remove `PostResizeValidator` calls from `ResizeObserver.scheduleReapplyWhenMouseUp`
- [ ] Remove `PostResizeValidator` call from `OrganizeHandler.organize()`

---

## Context / Problem

`ReapplyHandler.reapplyAll()` applies the full window layout via AX calls. It can be triggered multiple times in rapid succession — for example when multiple windows are snapped in sequence (`OrganizeHandler`), or when AX notifications fire in bursts after a resize/swap.

**Problem 1 — no debounce:** Multiple calls within a short window each synchronously invoke `LayoutService.applyLayout`, causing redundant AX calls, visual flicker, and potential re-entrancy.

**Problem 2 — validator fires too early:** `PostResizeValidator.checkAndFixRefusals` is scheduled by callers 0.3s after *initiating* the reapply. If `reapplyAll()` is called more than once in that window (debounced or not), the validator may run before the final layout application settles.

**Goal:** Collapse rapid `reapplyAll()` calls into a single execution 100ms after the last call. Always schedule the validator 0.3s after *that* execution, not after the first trigger.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/System/ReapplyHandler.swift` | Modify — add 100ms debounce; internalize `reapplying` management and validator scheduling |
| `UnnamedWindowManager/Observation/ResizeObserver.swift` | Modify — remove explicit `reapplying` set/clear and `PostResizeValidator` calls |
| `UnnamedWindowManager/System/OrganizeHandler.swift` | Modify — remove explicit `PostResizeValidator` call |

**Unaffected callers** (just call `reapplyAll()`, no manual `reapplying`/validator management — debounce is transparent):

| File | Call site |
|------|-----------|
| `UnnamedWindowManager/Observation/ResizeObserver.swift` | Line 73 — window destruction path |
| `UnnamedWindowManager/Observation/ScreenChangeObserver.swift` | Line 21 — screen change handler |
| `UnnamedWindowManager/System/SnapHandler.swift` | Lines 29, 47 — snap focused / snap left |
| `UnnamedWindowManager/System/UnsnapHandler.swift` | Line 25 — unsnap focused window |
| `UnnamedWindowManager/System/OrientFlipHandler.swift` | Line 22 — flip parent orientation |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Lines 47, 71, 77 — Refresh menu item, config reload, key restart |

---

## Implementation Steps

### 1. Debounce `ReapplyHandler.reapplyAll()`

Add a static stored `pendingLayout` work item. Each call cancels any pending item and reschedules it 100ms out. The deferred block performs the actual layout, manages `reapplying`, and schedules the validator.

```swift
// ReapplyHandler.swift
private static var pendingLayout: DispatchWorkItem?

static func reapplyAll() {
    pendingLayout?.cancel()
    let work = DispatchWorkItem {
        guard let screen = NSScreen.main else { return }
        pruneOffScreenWindows(screen: screen)
        let leaves = SnapService.shared.leavesInVisibleRoot()
        let allWindows = Set(leaves.compactMap { leaf -> WindowSlot? in
            if case .window(let w) = leaf { return w }
            return nil
        })
        ResizeObserver.shared.reapplying.formUnion(allWindows)
        LayoutService.shared.applyLayout(screen: screen)
        WindowVisibilityManager.shared.applyVisibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            ResizeObserver.shared.reapplying.subtract(allWindows)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let screen = NSScreen.main else { return }
            PostResizeValidator.checkAndFixRefusals(windows: allWindows, screen: screen)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .snapStateChanged, object: nil)
        }
    }
    pendingLayout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
}
```

The `snapStateChanged` notification is posted async inside the deferred block (unchanged semantics, just moved).

### 2. Clean up `ResizeObserver.scheduleReapplyWhenMouseUp`

In both the `isResize` and move/swap branches, remove:
- `self.reapplying.formUnion(allWindows)` — now handled inside `reapplyAll()`
- `DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.reapplying.subtract(allWindows) }` — same
- `DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { PostResizeValidator... }` — now handled inside `reapplyAll()`
- The `allWindows` local var computation (if no longer needed)

The resize branch simplifies to:
```swift
if isResize {
    guard let screen = NSScreen.main,
          let axElement = self.elements[key],
          let actualSize = readSize(of: axElement) else { return }
    SnapService.shared.resize(key: key, actualSize: actualSize, screen: screen)
    ReapplyHandler.reapplyAll()
}
```

The move/swap branch (drop allowed) simplifies to:
```swift
if drop.zone == .center {
    SnapService.shared.swap(key, drop.window)
} else if let screen = NSScreen.main {
    SnapService.shared.insertAdjacent(dragged: key, target: drop.window,
                                      zone: drop.zone, screen: screen)
}
ReapplyHandler.reapplyAll()
```

The restore-only branch (no drop) is unchanged — it calls `ReapplyHandler.reapply(window:key:)` not `reapplyAll()`, so it is not affected by the debounce.

### 3. Clean up `OrganizeHandler.organize()`

Remove the explicit `PostResizeValidator` asyncAfter call:

```swift
// before:
ReapplyHandler.reapplyAll()
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    guard let screen = NSScreen.main else { return }
    PostResizeValidator.checkAndFixRefusals(windows: snappedKeys, screen: screen)
}

// after:
ReapplyHandler.reapplyAll()
```

`reapplyAll()` will internally validate all currently tracked windows 0.3s after it executes. The `snappedKeys` set passed to the validator in the old code is a subset of all tracked windows; the new internal validator uses all leaves in the visible root, which is equivalent or broader — this is fine since `checkAndFixRefusals` already filters by `windows.contains(w)`.

---

## Key Technical Notes

- `reapplying` must be set *before* `applyLayout` runs to suppress re-entrant AX notifications from layout-triggered window moves. Moving it inside the deferred block (right before `applyLayout`) preserves this invariant.
- During the 100ms debounce window, `reapplying` is not set. Any AX notifications arriving in that window will call `scheduleReapplyWhenMouseUp`, which calls `reapplyAll()`, which extends the debounce — this is the desired behavior.
- `reapply(window:key:)` (single-window restore) is NOT debounced — it has its own guard via `reapplying.insert(key)` and is a targeted no-op if the window is already in the correct position.
- The `pendingLayout` work item is static, so only one debounce is active at a time across all callers.
- `PostResizeValidator` uses `leavesInVisibleRoot()` at execution time, reflecting the latest tree state — this is correct since we want the validator to check windows as they are after all operations complete.

---

## Verification

1. Snap two windows → resize one → both windows reposition correctly after ~100ms, validator fires once ~400ms later.
2. Trigger `OrganizeHandler.organize()` with 4 windows → all snap, validator fires once after debounce settles.
3. Drag one window over another for a swap → release → windows swap positions, validator fires once.
4. Rapidly press the organize shortcut twice within 100ms → layout applies once, not twice (check logs for single `applyLayout` call per burst).
5. Resize a window that refuses the target size → notification appears, second layout pass corrects adjacent windows.
