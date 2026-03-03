# Plan: 12_window_events — Window Close Reflow + Auto-Snap

## Checklist

### Window close reflow (done)
- [x] Add `removeAndReflow(_:screen:)` to `ManagedSlotRegistry.swift`
- [x] Update `ResizeObserver.swift` destroy handler to call new method and trigger `reapplyAll()`

### Auto-snap new windows
- [x] Add `registerFirst(_:width:height:)` to `ManagedSlotRegistry.swift`
- [x] Add `snapLeft(window:pid:)` to `WindowSnapper.swift`
- [x] Create `WindowEventMonitor.swift` — subscribe to `kAXWindowCreatedNotification` for all running apps + new launches
- [x] Update `UnnamedWindowManagerApp.swift` — call `WindowEventMonitor.shared.start()` on init

---

## Problem

When a managed window is closed, the destroy handler currently:
1. Calls `ManagedSlotRegistry.shared.remove(key)` — removes the window; removes the slot if it's now empty.
2. Calls `cleanup(key:pid:)` — removes the key from `elements` and other observer state.

But it **does not**:
- Equalize heights of the remaining windows in the slot.
- Reposition any windows after the layout changes.

Result: if slot A had windows [X, Y] and Y is closed, X is left with its original half-height and is not repositioned. If a slot is removed entirely, the slots to its right are not shifted left.

---

## Behaviour spec

| Situation | Expected result |
|-----------|----------------|
| Closed window was the **only** window in its slot | Slot is removed; all remaining slots are repositioned left-to-right as usual via `reapplyAll()` |
| Closed window shared its slot with other windows | Remaining windows in the slot have their heights **equalized** (same logic as `equalizeHeights`); then `reapplyAll()` repositions everything |

---

## Implementation

### Why a new method instead of modifying `remove`

`remove(_:)` is also called by `unsnap()` (manual unsnap via keyboard shortcut). That path intentionally does **not** reflow the remaining windows — the user is removing a window from management, not closing it. Adding reflow there would be a behaviour change. A separate `removeAndReflow(_:screen:)` keeps the two paths distinct.

### Sync vs async barrier

The existing `remove(_:)` uses `queue.async(flags: .barrier)`. If we called `reapplyAll()` right after, the async barrier would not have completed yet, so `reapplyAll()` would read stale data. The new method uses `queue.sync(flags: .barrier)` so the mutation is committed before control returns and `reapplyAll()` is called.

---

## Files to modify

| File | Action |
|------|--------|
| `ManagedSlotRegistry.swift` | Add `removeAndReflow(_:screen:)` |
| `ResizeObserver.swift` | Update `kElementDestroyed` branch |

---

## Implementation Details

### 1. `ManagedSlotRegistry.swift` — add `removeAndReflow`

```swift
/// Removes a window from its slot (called on window close).
/// If other windows remain in the slot, equalizes their heights.
/// If the slot becomes empty, removes it.
/// Uses a synchronous barrier so callers can immediately call `reapplyAll()`.
func removeAndReflow(_ key: ManagedWindow, screen: NSScreen) {
    let visibleHeight = screen.visibleFrame.height

    queue.sync(flags: .barrier) {
        for si in self.slots.indices {
            guard let wi = self.slots[si].windows.firstIndex(of: key) else { continue }
            self.slots[si].windows.remove(at: wi)
            if self.slots[si].windows.isEmpty {
                self.slots.remove(at: si)
            } else {
                self.equalizeHeights(inSlot: si, visibleHeight: visibleHeight)
            }
            return
        }
    }
}
```

`equalizeHeights(inSlot:visibleHeight:)` is already a private helper in `ManagedSlotRegistry+SlotMutations.swift`. Move it to `ManagedSlotRegistry.swift` (or keep it in the extension and make it `internal` rather than `private`) so it is accessible from the new method.

> **Alternative**: keep `equalizeHeights` private in the extension and inline the same logic in `removeAndReflow`. This avoids changing access level. Either approach works — the inline version is simpler.

### 2. `ResizeObserver.swift` — update destroy handler

Current code (lines 64–68):

```swift
if notification == kElementDestroyed as String {
    ManagedSlotRegistry.shared.remove(key)
    cleanup(key: key, pid: pid)
    return
}
```

New code:

```swift
if notification == kElementDestroyed as String {
    if let screen = NSScreen.main {
        ManagedSlotRegistry.shared.removeAndReflow(key, screen: screen)
    } else {
        ManagedSlotRegistry.shared.remove(key)
    }
    cleanup(key: key, pid: pid)
    WindowSnapper.reapplyAll()
    return
}
```

**Order matters:**
1. `removeAndReflow` — mutates the registry synchronously (barrier). The closed window is gone from `slots`.
2. `cleanup` — removes the closed window's key from `elements`. After this, `ResizeObserver.shared.window(for: closedWin)` returns `nil`.
3. `reapplyAll()` — iterates `allSlots()`, looks up each window in `elements`. The closed window is absent from both `slots` and `elements`, so it is naturally skipped. All remaining windows are repositioned correctly.

---

## Verification — window close

1. **Single-window slot close**: Snap A | B. Close B. A expands to full height; layout becomes just A. No stale gap or offset.
2. **Multi-window slot close**: Snap A slot with [X, Y] vertically. Close Y. X expands to full slot height. X is repositioned correctly.
3. **Multi-window slot close (middle)**: Slot has [X, Y, Z]. Close Y. X and Z share the slot height equally. Both are repositioned.
4. **Manual unsnap unaffected**: Snap A | B. Unsnap B via keyboard. A is not moved (existing behaviour preserved — `remove` is still used by `unsnap()`).
5. **Empty registry**: Close the last managed window. `reapplyAll()` iterates an empty slot list — no crash.

---

## Auto-snap new windows

### Problem

Currently a new window must be snapped manually via the "Snap" menu item. There is no automatic detection when a window is created by any application.

### Behaviour spec

When any regular application window is created, it is automatically snapped as a new slot at the **leftmost** position (index 0). All existing slots shift right. The new slot's width is taken from the window's current width (clamped); its height is full visible height.

| Situation | Expected result |
|-----------|----------------|
| New window from an already-managed app | Snapped to the left; existing slots shift right |
| New window from a freshly launched app | Same — `WindowEventMonitor` subscribes to new apps as they launch |
| Window is too small (w < 100 or h < 100) | Ignored — likely a panel or popover |
| Window is minimized at creation | Ignored |
| Window is already tracked | Ignored (duplicate `kAXWindowCreatedNotification`) |

### Detection mechanism

The macOS AX API fires `kAXWindowCreatedNotification` on the **application element** when a new window is created. The `element` passed to the callback is the new window itself.

`WindowEventMonitor` maintains its own AXObserver per PID (separate from `ResizeObserver`'s per-window observers) used solely for this app-level notification. This avoids any conflict with the existing cleanup logic in `ResizeObserver.cleanup`.

### Why insert at index 0 ("snap left")

New windows appear with their own position and size. Inserting at slot 0 places them at the left edge of the managed area, consistent with a left-to-right append model — the new window anchors the layout from the left and existing slots shift right.

---

## Files to modify — auto-snap

| File | Action |
|------|--------|
| `ManagedSlotRegistry.swift` | Add `registerFirst(_:width:height:)` |
| `WindowSnapper.swift` | Add `snapLeft(window:pid:)` |
| `WindowEventMonitor.swift` | **New file** — app-level AX subscription + NSWorkspace launch notifications |
| `UnnamedWindowManagerApp.swift` | Call `WindowEventMonitor.shared.start()` in `init()` |

---

## Implementation Details — auto-snap

### 1. `ManagedSlotRegistry.swift` — add `registerFirst`

```swift
/// Registers a new window as a new slot prepended at the left (index 0).
func registerFirst(_ key: ManagedWindow, width: CGFloat, height: CGFloat) {
    queue.async(flags: .barrier) {
        let window = ManagedWindow(pid: key.pid, windowHash: key.windowHash, height: height)
        self.slots.insert(ManagedSlot(width: width, windows: [window]), at: 0)
    }
}
```

`queue.async(flags: .barrier)` is sufficient: `applyPosition` and `reapplyAll` both call `queue.sync`, which serializes after the barrier, so they observe the updated state.

---

### 2. `WindowSnapper.swift` — add `snapLeft`

```swift
/// Snaps `window` as a new slot at position 0 (leftmost).
/// Skips windows that are already tracked, minimized, or too small.
static func snapLeft(window: AXUIElement, pid: pid_t) {
    guard AXIsProcessTrusted() else { return }
    guard let screen = NSScreen.main else { return }

    let key = managedWindow(for: window, pid: pid)
    guard !ManagedSlotRegistry.shared.isTracked(key) else { return }

    // Ignore minimized windows.
    var minRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
       (minRef as? Bool) == true { return }

    // Ignore panels and popovers (too small).
    if let sz = readSize(of: window), sz.width < 100 || sz.height < 100 { return }

    let visible = screen.visibleFrame
    let rawSize = CGSize(
        width:  readSize(of: window)?.width ?? visible.width * Config.fallbackWidthFraction,
        height: visible.height - Config.gap * 2
    )
    let clamped = clampSize(rawSize, screen: screen)

    ManagedSlotRegistry.shared.registerFirst(key, width: clamped.width, height: clamped.height)
    applyPosition(to: window, key: key)
    ResizeObserver.shared.observe(window: window, pid: pid, key: key)
    reapplyAll()
}
```

---

### 3. `WindowEventMonitor.swift` — new file

```swift
//
//  WindowEventMonitor.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

// C-compatible callback — receives new-window elements from app-level observers.
// refcon is unused (nil); pid is retrieved from the element directly.
private func appWindowCreatedCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,       // the newly created window
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    // Callback is delivered on main thread (run loop source added to main).
    WindowSnapper.snapLeft(window: element, pid: pid)
}

final class WindowEventMonitor {
    static let shared = WindowEventMonitor()
    private init() {}

    /// AXObservers keyed by PID — used solely for app-level kAXWindowCreatedNotification.
    private var appObservers: [pid_t: AXObserver] = [:]

    func start() {
        guard AXIsProcessTrusted() else { return }

        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID else { continue }
            subscribe(pid: app.processIdentifier)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
        subscribe(pid: app.processIdentifier)
    }

    private func subscribe(pid: pid_t) {
        guard appObservers[pid] == nil else { return }

        var axObs: AXObserver?
        guard AXObserverCreate(pid, appWindowCreatedCallback, &axObs) == .success,
              let axObs else { return }

        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(axObs, appElement, kAXWindowCreatedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        appObservers[pid] = axObs
    }
}
```

Key points:
- **Separate observers from `ResizeObserver`** — no interference with `cleanup` logic.
- **`appWindowCreatedCallback` is a plain C function** — no Swift capture. The `pid` is derived from the element, not refcon.
- **`subscribe` is idempotent** — guards against double-registration for the same PID.
- **All state is accessed on main thread** — `start()` and `appLaunched` are always on main; the AX callback run loop source is added to main.

---

### 4. `UnnamedWindowManagerApp.swift` — start monitoring

```swift
@main
struct UnnamedWindowManagerApp: App {
    init() {
        WindowEventMonitor.shared.start()
    }
    ...
}
```

`init()` runs before the first scene body evaluation and is guaranteed to run on the main thread for `@main` entry points.

---

## Verification — auto-snap

1. **Fresh launch**: Start the app. Open any regular app window. It snaps automatically to the left at full height.
2. **Multiple opens**: Open a second window. It snaps to the left; the first window's slot shifts right.
3. **Existing windows on launch**: Windows already on screen when the app starts are **not** auto-snapped (they are not new — no `kAXWindowCreatedNotification` fires for them). Use "Organize" to snap those manually.
4. **Small/panel windows**: Open a preferences panel (small window). It is not snapped.
5. **Minimized window at create**: Not applicable in practice — windows are not created in minimized state.
6. **New app launch**: Launch a brand-new app after `start()` runs. `NSWorkspace.didLaunchApplicationNotification` fires, `subscribe(pid:)` registers the new observer, and subsequent window creation is snapped.
7. **Duplicate notification**: `isTracked` guard in `snapLeft` prevents double-registration if `kAXWindowCreatedNotification` fires more than once for the same window.
