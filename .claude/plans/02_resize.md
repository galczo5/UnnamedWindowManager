# Plan: 02_resize — Persistent Snap State & Resize Guard

## Checklist

- [x] Create `SnapRegistry.swift` — singleton that stores snapped window identifiers
- [x] Extend `WindowSnapper.swift` — register windows on snap, expose `reapply` method
- [x] Create `ResizeObserver.swift` — AX observer that watches for move/resize events on tracked windows
- [x] Wire `ResizeObserver` into the app lifecycle in `UnnamedWindowManagerApp.swift`

---

## Context

After 01_init, windows snap correctly on demand but the snap has no persistence — the user can freely drag or resize the window away. The goal of this plan is to **remember which windows are snapped and to which side**, and to automatically reapply the snap whenever the user moves or resizes such a window, keeping it consistent until the user explicitly unsnaps it.

---

## Files to create / modify

| File | Action |
|---|---|
| `UnnamedWindowManager/SnapRegistry.swift` | Create — stores snapped window identity and target side |
| `UnnamedWindowManager/WindowSnapper.swift` | Modify — register on snap, add `reapply(window:)` helper |
| `UnnamedWindowManager/ResizeObserver.swift` | Create — AX notification observer for move/resize events |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — start/stop `ResizeObserver` with app lifecycle |

---

## Implementation Steps

### 1. Design a window identity strategy

AX windows don't have stable UUIDs. Use a composite key derived from:
- `pid` of the owning process (`pid_t` from `NSRunningApplication`)
- The `AXUIElement` pointer value (`CFHash` / `UInt`) of the window element

Store the key as `struct SnapKey: Hashable { let pid: pid_t; let windowHash: UInt }`.

> Note: `AXUIElement` pointers can be reused after a window closes; always validate the element with an `AXUIElementCopyAttributeValue` probe before reapplying.

---

### 2. `SnapRegistry.swift`

A thread-safe (actor-isolated or `DispatchQueue`-protected) registry:

```swift
enum SnapSide { case left, right }

struct SnapKey: Hashable {
    let pid: pid_t
    let windowHash: UInt
}

final class SnapRegistry {
    static let shared = SnapRegistry()
    private var store: [SnapKey: SnapSide] = [:]
    private let queue = DispatchQueue(label: "snap.registry", attributes: .concurrent)

    func register(_ key: SnapKey, side: SnapSide) {
        queue.async(flags: .barrier) { self.store[key] = side }
    }

    func side(for key: SnapKey) -> SnapSide? {
        queue.sync { store[key] }
    }

    func remove(_ key: SnapKey) {
        queue.async(flags: .barrier) { self.store.removeValue(forKey: key) }
    }

    func isTracked(_ key: SnapKey) -> Bool {
        side(for: key) != nil
    }
}
```

---

### 3. Update `WindowSnapper.swift`

After a successful `AXUIElementSetAttributeValue` call, compute the `SnapKey` and call `SnapRegistry.shared.register(key, side:)`.

Add a helper:

```swift
static func snapKey(for window: AXUIElement, pid: pid_t) -> SnapKey {
    SnapKey(pid: pid, windowHash: UInt(bitPattern: CFHash(window)))
}

static func reapply(window: AXUIElement, pid: pid_t) {
    let key = snapKey(for: window, pid: pid)
    guard let side = SnapRegistry.shared.side(for: key) else { return }
    applyFrame(to: window, side: side)   // extracted internal helper
}
```

Extract the frame-setting logic into a private `applyFrame(to:side:)` so both `snap(_:)` and `reapply` share it.

---

### 4. `ResizeObserver.swift`

Use `AXObserver` to watch `kAXWindowMovedNotification` and `kAXWindowResizedNotification` on each application whose windows are registered.

**Key points:**
- Create one `AXObserver` per tracked PID via `AXObserverCreate`.
- Register notifications on the **window element** (not the app element) using `AXObserverAddNotification`.
- Add the observer to the run loop with `CFRunLoopAddSource`.
- In the callback, call `WindowSnapper.reapply(window:pid:)` — but guard with a short debounce (~0.1 s) to avoid infinite reapply loops (the reapply itself triggers a moved notification).
- Remove and release observers for PIDs that no longer have tracked windows.

```swift
final class ResizeObserver {
    static let shared = ResizeObserver()
    private var observers: [pid_t: AXObserver] = [:]

    func observe(window: AXUIElement, pid: pid_t) { … }
    func stopObserving(pid: pid_t) { … }
}
```

**Debounce / re-entrancy guard:**
Maintain a `Set<SnapKey>` of "currently reapplying" keys. Before calling `WindowSnapper.reapply`, insert the key; skip if already present. Remove the key after the reapply (or after a short delay) to allow future user moves to be caught again.

---

### 5. Wire into app lifecycle

In `UnnamedWindowManagerApp.swift`, start `ResizeObserver.shared` at launch (it self-manages per-window registrations) and stop all observations on termination.

Optionally add an **"Unsnap"** menu item that calls `SnapRegistry.shared.remove(key)` + `ResizeObserver.shared.stopObserving(pid:)` for the frontmost snapped window.

---

## Key Technical Notes

- **AX notification loop guard**: `kAXWindowMovedNotification` fires when your own `AXUIElementSetAttributeValue(kAXPositionAttribute)` runs. The debounce / in-flight guard is mandatory to prevent infinite recursion.
- **Window element validity**: Before reapplying, probe the window with `AXUIElementCopyAttributeValue(window, kAXTitleAttribute, ...)`. If it returns `kAXErrorInvalidUIElement`, remove the key from the registry and stop observing.
- **Multiple screens**: All frame math uses `NSScreen.main?.visibleFrame`; reapply must re-query it in case the user moved the window to a different screen.
- **Per-PID observer limit**: macOS allows one `AXObserver` per PID; add all window notifications through that single observer.
- **Thread safety**: AX callbacks arrive on the main run loop thread; keep all registry mutations on the same thread or use the concurrent queue with barrier writes.

---

## Verification

1. Snap a Finder window left — it snaps.
2. Try to drag it away — it snaps back to the left edge.
3. Try to resize it — it reapplies the full snap geometry.
4. Open a second window, snap it right — both windows independently maintain their snap.
5. Close a snapped window — no crashes; registry cleans up the stale key.
6. (Optional) Add an "Unsnap" button; click it — the frontmost window can now be moved/resized freely.
