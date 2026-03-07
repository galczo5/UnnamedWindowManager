# Plan: 12_auto_snap — Automatically snap new windows when autoSnap is enabled

## Checklist

- [x] Add `autoSnap: Bool` to `Config.swift`
- [x] Create `AutoSnapObserver.swift` with workspace + AX window-created observer
- [x] Create `autoSnapCallback` C-compatible AX callback in `AutoSnapObserver.swift`
- [x] Start `AutoSnapObserver` from `UnnamedWindowManagerApp.init()` when `autoSnap` is true

---

## Context / Problem

Currently all snapping is manual: the user must click "Snap" in the menu bar or the app relies on
`SnapHandler.snapLeft` being called explicitly. There is no mechanism to snap windows that appear
without user intervention.

Goal: when `Config.autoSnap == true`, any window that comes to the foreground (app activation) or
is freshly created (new window within the active app) is automatically snapped into the layout.

---

## Behaviour spec

- `Config.autoSnap = false` by default — existing behaviour is unchanged.
- When `true`, two trigger paths snap the frontmost window:
  1. **App activation** (`NSWorkspace.didActivateApplicationNotification`) — fires when the user
     switches to a different app. The newly active app's focused window is snapped.
  2. **Window created** (`kAXWindowCreatedNotification`) — fires when any observed app opens a new
     window (e.g. Cmd+N). The focused window of that app is snapped.
- **Precondition**: both paths are no-ops unless `SnapService.shared.snapshotVisibleRoot() != nil`,
  i.e. at least one window is already snapped and visible on the current screen. This prevents
  autoSnap from spontaneously starting a layout when the user has not opted in by snapping manually
  first.
- Both paths call `SnapHandler.snapLeft`, which is already idempotent (no-op if the window is
  minimised, smaller than 100×100, or already tracked).
- Per-app AX observers are created lazily on first activation and removed when the app terminates.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Config.swift` | Modify — add `static let autoSnap: Bool = false` |
| `UnnamedWindowManager/Observation/AutoSnapObserver.swift` | **New file** — singleton observer |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — start observer in `init()` |

---

## Implementation Steps

### 1. Add `autoSnap` to Config

Add one line to the `Config` enum:

```swift
static let autoSnap: Bool = false
```

### 2. Create `AutoSnapObserver.swift`

New file in `Observation/`. The singleton:
- Registers for `NSWorkspace` notifications on `start()`.
- Maintains a `[pid_t: AXObserver]` map for app-level AX observers (separate from
  `ResizeObserver`'s per-window map).
- Cleans up AX observers when apps terminate.

```swift
final class AutoSnapObserver {
    static let shared = AutoSnapObserver()
    private init() {}

    private var appObservers: [pid_t: AXObserver] = [:]

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(didActivateApp(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(didTerminateApp(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func didActivateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let pid = app.processIdentifier
        observeApp(pid: pid)
        snapFocusedWindow(pid: pid)
    }

    @objc private func didTerminateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        removeAppObserver(pid: app.processIdentifier)
    }

    private func observeApp(pid: pid_t) {
        guard appObservers[pid] == nil else { return }
        var axObs: AXObserver?
        guard AXObserverCreate(pid, autoSnapCallback, &axObs) == .success, let axObs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(axObs, appEl, kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        appObservers[pid] = axObs
    }

    private func removeAppObserver(pid: pid_t) {
        guard let axObs = appObservers[pid] else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        appObservers.removeValue(forKey: pid)
    }

    func handleWindowCreated(pid: pid_t) {
        snapFocusedWindow(pid: pid)
    }

    private func snapFocusedWindow(pid: pid_t) {
        // Only auto-snap when a layout is already active on screen.
        guard SnapService.shared.snapshotVisibleRoot() != nil else { return }
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success
        else { return }
        SnapHandler.snapLeft(window: ref as! AXUIElement, pid: pid)
    }
}
```

### 3. C-compatible callback for `kAXWindowCreatedNotification`

In the same file (outside the class, just like `axNotificationCallback` in `AXCallback.swift`):

```swift
private func autoSnapCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let obs = Unmanaged<AutoSnapObserver>.fromOpaque(refcon).takeUnretainedValue()
    obs.handleWindowCreated(pid: pid)
}
```

`kAXWindowCreatedNotification` passes the **application** element as `element`, not the new
window. The focused window is queried via `kAXFocusedWindowAttribute` in `snapFocusedWindow`.

### 4. Start the observer in `UnnamedWindowManagerApp`

In `UnnamedWindowManagerApp.init()`, after existing setup:

```swift
if Config.autoSnap {
    AutoSnapObserver.shared.start()
}
```

---

## Key Technical Notes

- `kAXWindowCreatedNotification` delivers the **application** AX element, not the new window — use
  `kAXFocusedWindowAttribute` to retrieve the window.
- AX callbacks arrive on the main run loop (same as `ResizeObserver`); no extra dispatch needed.
- `SnapService.shared.snapshotVisibleRoot()` is the same call used by `MenuState.refresh()` to
  detect whether a layout is active — reuse it as the precondition gate in `snapFocusedWindow`.
- `SnapHandler.snapLeft` is idempotent: size check, minimised check, and `SnapService.snap` are
  all no-ops on already-tracked windows — safe to call speculatively.
- Per-app AX observers in `AutoSnapObserver` are distinct from per-window observers in
  `ResizeObserver`. They observe the **app element**, not individual windows.
- `NSWorkspace.didActivateApplicationNotification` does not fire for the app that is active at
  launch; call `observeApp` + `snapFocusedWindow` in `start()` if snap-on-launch is needed.
- Clean up `appObservers` on terminate to avoid leaking run loop sources for dead PIDs.

---

## Verification

1. Set `Config.autoSnap = true`, build and run.
2. With **no** snapped windows: open TextEdit → window does **not** auto-snap (precondition fails).
3. Manually snap one window via the "Snap" menu item → layout is now active.
4. Switch to TextEdit → its window snaps automatically.
5. Press Cmd+N in TextEdit → the new window snaps automatically.
6. Switch to Safari → its frontmost window snaps.
7. Switch back to an already-snapped window → no duplicate snap, layout unchanged.
8. Unsnap all windows so no layout is active; switch to another app → no auto-snap.
9. Set `Config.autoSnap = false`, rebuild → no auto-snapping at any point; manual snap still works.
10. Quit an observed app → verify no crash and the terminated app's observer is cleaned up.
