# Plan: 19_fix_dim_infinite_loop — Fix infinite loop in applyDimForFrontmostWindow

## Checklist

- [x] Remove `kAXRaiseAction` call from `applyDimForFrontmostWindow`
- [x] Add `pendingDim: DispatchWorkItem?` debounce (100 ms) to `FocusObserver`
- [x] Re-enable `applyDimForFrontmostWindow` in `focusChangedCallback`
- [x] Re-enable `applyDimForFrontmostWindow` in `didActivateApp`
- [x] Re-enable `applyDimForFrontmostWindow` in `start()`
- [x] Remove all TODO loop comments

---

## Context / Problem

`FocusObserver.applyDimForFrontmostWindow` was working correctly but got commented out because it caused an infinite loop. The symptom was rapid-fire log output:

```
[TileService.swift] snapshotVisibleRoot()
[TileService.swift] isTracked(_:): hash=...
[TileService.swift] snapshotVisibleRoot()
...
```

**Root cause:** Inside `applyDimForFrontmostWindow`, there is:

```swift
AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
```

This unconditionally raises the AX-focused window via the Accessibility API. Raising a window via AX triggers a new `kAXFocusedWindowChangedNotification` for that app's AX observer. That notification fires `focusChangedCallback`, which then calls `applyDimForFrontmostWindow` again, which raises again, and so on.

The loop is not synchronous re-entrancy — it is a run-loop ping-pong:
1. `applyDimForFrontmostWindow` → `kAXRaiseAction`
2. Run loop: new `kAXFocusedWindowChangedNotification` fires
3. `focusChangedCallback` → schedules another `applyDimForFrontmostWindow` async
4. Current call finishes; next dispatch runs (step 1 again)

The scrolling root case mentioned in the TODO is a secondary concern: when the focused window is in a `ScrollingRootSlot`, `ScrollingTileService.isTracked` returns `true`, so the code falls to the `else` branch and calls `restoreAll()`. That is already correct behavior. The loop happens regardless because the raise is called **before** the if/else branch.

**Goal:** Re-enable window dimming by removing the raise call (the loop's trigger), then uncommenting the three call sites.

---

## Why removing kAXRaiseAction is safe

The raise was added so "the window server reflects the correct Z-order before the overlay is positioned below it." However:

- When `kAXFocusedWindowChangedNotification` fires, the user has already focused the window — it is already frontmost from the user's perspective.
- `WindowOpacityService.dim()` orders the overlay using `win.order(.below, relativeTo: Int(focusedHash))`, where `focusedHash` is the `CGWindowID`. This positions the overlay just below the focused window's compositor layer, which is correct the moment the window is focused.
- The only case where the window might not yet be frontmost is programmatic focus (e.g., `AXUIElementSetAttributeValue` with `kAXFocusedWindowAttribute`). For the current use cases (user clicks, app activation) the raise is redundant.

---

## Debounce

Focus events can arrive in bursts — the user tabs through windows, an app switches focus programmatically, or a `didActivateApp` notification and a `kAXFocusedWindowChangedNotification` both fire within milliseconds of each other. Without debouncing, each event would kick off a full AX query (`AXUIElementCopyAttributeValue`) and an overlay animation.

Add a `pendingDim: DispatchWorkItem?` property to `FocusObserver` (same pattern as `ReapplyHandler.pendingLayout`). Every call to `applyDimForFrontmostWindow` cancels the previous pending item and schedules a new one 100 ms out. Only the last event in a burst executes.

The `start()` call-site is a one-time boot-time call — it should skip the debounce and call the implementation directly so the initial dim state is applied immediately on launch.

```swift
private var pendingDim: DispatchWorkItem?

func applyDimForFrontmostWindow(pid: pid_t) {
    pendingDim?.cancel()
    let work = DispatchWorkItem { [weak self] in
        self?.pendingDim = nil
        self?.executeDim(pid: pid)
    }
    pendingDim = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
}

private func executeDim(pid: pid_t) {
    // ... the AX query + WindowOpacityService call (formerly applyDimForFrontmostWindow body)
}
```

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Observation/FocusObserver.swift` | Modify — remove raise, uncomment call sites, remove TODO comments |

---

## Implementation Steps

### 1. Remove kAXRaiseAction and add debounce

Delete the raise block and split `applyDimForFrontmostWindow` into a public debouncing entry point and a private `executeDim` that does the actual work:

```swift
private var pendingDim: DispatchWorkItem?

func applyDimForFrontmostWindow(pid: pid_t) {
    pendingDim?.cancel()
    let work = DispatchWorkItem { [weak self] in
        self?.pendingDim = nil
        self?.executeDim(pid: pid)
    }
    pendingDim = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
}

private func executeDim(pid: pid_t) {
    let axApp = AXUIElementCreateApplication(pid)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success
    else {
        WindowOpacityService.shared.restoreAll()
        return
    }
    let axWindow = ref as! AXUIElement

    let elements = ResizeObserver.shared.elements
    if let (key, _) = elements.first(where: { CFEqual($0.value, axWindow) }),
       !ScrollingTileService.shared.isTracked(key),
       let rootID = TileService.shared.rootID(containing: key) {
        WindowOpacityService.shared.dim(rootID: rootID, focusedHash: key.windowHash)
    } else {
        WindowOpacityService.shared.restoreAll()
    }
}
```

The `start()` call-site calls `executeDim` directly (bypassing debounce) so the initial dim state is set synchronously on launch.

### 2. Re-enable in focusChangedCallback

The callback already dispatches work async on the main queue. Add the `applyDimForFrontmostWindow` call inside the same dispatch block:

```swift
private func focusChangedCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let obs = Unmanaged<FocusObserver>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .windowFocusChanged, object: nil)
        obs.applyDimForFrontmostWindow(pid: pid)
    }
}
```

### 3. Re-enable in didActivateApp

Uncomment the existing line:

```swift
@objc private func didActivateApp(_ note: Notification) {
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    else { return }
    let pid = app.processIdentifier
    observeApp(pid: pid)
    NotificationCenter.default.post(name: .windowFocusChanged, object: nil)
    applyDimForFrontmostWindow(pid: pid)
}
```

### 4. Re-enable in start()

Call `executeDim` directly (bypasses the 100 ms debounce) so the initial overlay is applied immediately:

```swift
if let app = NSWorkspace.shared.frontmostApplication {
    observeApp(pid: app.processIdentifier)
    executeDim(pid: app.processIdentifier)
}
```

---

## Key Technical Notes

- AX observers added with `CFRunLoopGetMain()` fire on the main run loop — all call sites remain on the main thread.
- `kAXRaiseAction` is the sole cause of the notification ping-pong. Without it, no new `kAXFocusedWindowChangedNotification` is generated by `executeDim`.
- The scrolling root `else` branch (`restoreAll()`) is correct and stays unchanged — focused windows in a `ScrollingRootSlot` should not trigger dimming.
- `executeDim` accesses `ResizeObserver.shared.elements` which is main-thread-only mutable state.
- The `DispatchQueue.main.async` wrapper previously wrapping the `dim()` call is removed — `executeDim` already runs on main (dispatched by `applyDimForFrontmostWindow` via `asyncAfter`), so no extra hop is needed.
- `pendingDim` must be a `var` on the class (not a local), so it survives across run-loop turns to be cancelled by the next call.

---

## Verification

1. Tile two or more windows → both visible on screen.
2. Click one window — the overlay should appear, dimming the non-focused tiled window.
3. Click the other tiled window — overlay should move (focused window changes).
4. Switch to a scrolling root window — overlay should disappear (restoreAll path).
5. Rapidly switch focus between tiled windows — no infinite loop in logs, no runaway CPU.
6. Switch to an unmanaged window — overlay disappears.
7. Check logs: `snapshotVisibleRoot` and `isTracked` should appear only once per focus event, not in a tight loop.
