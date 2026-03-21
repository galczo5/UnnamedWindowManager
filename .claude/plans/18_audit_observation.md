# Plan: 18_audit_observation — Audit and refactor Observation/ directory

## Checklist

- [x] Extract duplicated "remove window" logic in ResizeObserver.handle()
- [x] Extract duplicated observeApp/removeAppObserver pattern from AutoTileObserver and FocusObserver
- [x] Fix force unwrap in AutoTileObserver.tileFocusedWindow()
- [x] Fix force unwrap in FocusObserver.executeDim()
- [x] Remove trivial wrapper applyDimForFrontmostWindow in FocusObserver

---

## Context / Problem

The `Observation/` directory contains 8 files totalling ~780 lines. An audit found:

- **Duplication**: Three nearly identical "remove window from layout" blocks in `ResizeObserver.handle()` (destroyed, minimized, fullscreen) all performing the same 5-step sequence.
- **Duplication**: `AutoTileObserver` and `FocusObserver` share an identical pattern for managing per-app AXObservers — dictionary storage, creation, CFRunLoop add/remove, workspace notification subscription.
- **Force unwraps**: Two `as! AXUIElement` casts that can be safely unwrapped.
- **Trivial wrapper**: `applyDimForFrontmostWindow` is a one-line pass-through to `executeDim`, only called within the same file.

No dead code, no style violations, no decomposition issues (largest file is 276 lines).

---

## Files to create / modify

| File | Action |
|------|--------|
| `Observation/ResizeObserver.swift` | Modify — extract remove-window sequence to private helper |
| `Observation/AppObserverManager.swift` | **New file** — shared AXObserver lifecycle manager |
| `Observation/AutoTileObserver.swift` | Modify — delegate observer management to AppObserverManager |
| `Observation/FocusObserver.swift` | Modify — delegate observer management to AppObserverManager; remove wrapper; fix force unwrap |

---

## Implementation Steps

### 1. Extract remove-window helper in ResizeObserver

The three blocks in `handle()` (lines 71-86, 88-103, 105-124) all perform:
1. `WindowOpacityService.shared.restore(hash:)`
2. `removeAndReflow` / `remove` (scrolling-aware)
3. `cleanup(key:pid:)`
4. `WindowVisibilityManager.shared.windowRemoved(key)`
5. `ReapplyHandler.reapplyAll()`

Extract to a `private func removeWindow(key:pid:isScrolling:)` method.

### 2. Extract AppObserverManager

Both `AutoTileObserver` and `FocusObserver` maintain:
- `appObservers: [pid_t: AXObserver]`
- `observeApp(pid:)` — guard not already present, `AXObserverCreate`, add notification, add to run loop
- `removeAppObserver(pid:)` — remove from run loop, remove from dict
- `start()` subscribes to `didActivateApplicationNotification` + `didTerminateApplicationNotification` and observes frontmost app

The difference is which AX notification each subscribes to and which callback/handler runs. Extract the common lifecycle into a generic `AppObserverManager` that takes a callback and notification name at init, and exposes `start(onActivate:)` / `observeApp(pid:)` / `removeAppObserver(pid:)`.

```swift
// Manages per-app AXObserver lifecycle: creation, run-loop registration, and cleanup.
final class AppObserverManager {
    private var appObservers: [pid_t: AXObserver] = [:]
    private let callback: AXObserverCallback
    private let notification: CFString
    private let refcon: UnsafeMutableRawPointer

    init(callback: @escaping AXObserverCallback, notification: CFString, refcon: UnsafeMutableRawPointer) {
        self.callback = callback
        self.notification = notification
        self.refcon = refcon
    }

    func observeApp(pid: pid_t) {
        guard appObservers[pid] == nil else { return }
        var axObs: AXObserver?
        guard AXObserverCreate(pid, callback, &axObs) == .success, let axObs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(axObs, appEl, notification, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        appObservers[pid] = axObs
    }

    func removeAppObserver(pid: pid_t) {
        guard let axObs = appObservers[pid] else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        appObservers.removeValue(forKey: pid)
    }
}
```

### 3. Update AutoTileObserver to use AppObserverManager

Replace `appObservers` dict and `observeApp`/`removeAppObserver` methods with a stored `AppObserverManager` instance.

### 4. Update FocusObserver

- Replace `appObservers` dict and `observeApp`/`removeAppObserver` with `AppObserverManager`.
- Remove `applyDimForFrontmostWindow` wrapper — rename `executeDim` to `applyDim` and call it directly from both callsites.
- Fix force unwrap: `let axWindow = ref as! AXUIElement` → guard cast with early return.

### 5. Fix force unwrap in AutoTileObserver

`let window = ref as! AXUIElement` on line 109 → guard cast with early return.

---

## Key Technical Notes

- AX callbacks are C-function pointers — they cannot be unified into a single generic callback because each casts `refcon` to a different Swift type. This is inherent to the AXObserver API.
- `AppObserverManager` stores `refcon` as a raw pointer — callers must ensure the referenced object outlives the manager (both `AutoTileObserver` and `FocusObserver` are singletons, so this holds).
- The `start()` pattern (subscribing to workspace notifications) stays in each observer because the `onActivate` / `onTerminate` handlers differ beyond just observer management (e.g. `AutoTileObserver` also calls `tileFocusedWindow`).

---

## Verification

1. Build with `./build.sh` after each file change
2. Snap two windows → drag one over the other → overlay appears, swap works
3. Close a snapped window → layout reflows correctly
4. Minimize a snapped window → layout reflows correctly
5. Full-screen a snapped window → layout reflows correctly
6. Switch between apps → dimming updates correctly
7. Open a new window while layout is active → auto-tile works
