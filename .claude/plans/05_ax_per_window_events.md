# Plan: 05_ax_per_window_events — Per-window AX observers (move, resize, destroy, miniaturize, title)

## Checklist

- [ ] Create `WindowMovedEvent` in `Events/`
- [ ] Create `WindowMovedObserver` in `Observers/`
- [ ] Create `WindowResizedEvent` in `Events/`
- [ ] Create `WindowResizedObserver` in `Observers/`
- [ ] Create `WindowMiniaturizedEvent` in `Events/`
- [ ] Create `WindowMiniaturizedObserver` in `Observers/`
- [ ] Create `WindowDestroyedEvent` in `Events/`
- [ ] Create `WindowDestroyedObserver` in `Observers/`
- [ ] Create `WindowTitleChangedEvent` in `Events/`
- [ ] Create `WindowTitleChangedObserver` in `Observers/`
- [ ] Create `WindowEventRouter` to demux AX notifications into typed observers
- [ ] Migrate `ResizeObserver` tracking state into a new `WindowTracker` service
- [ ] Migrate handler logic into subscribers
- [ ] Delete `Services/Observation/ResizeObserver.swift`
- [ ] Delete `Services/Observation/AXCallback.swift`
- [ ] Update all references to `ResizeObserver.shared` across the codebase
- [ ] Verify build and all functionality

---

## Context / Problem

`ResizeObserver` is the most complex observer in the app (275 lines). It:
1. Manages per-window AXObserver registrations for 5 notification types
2. Maintains tracking dictionaries (`observers`, `elements`, `keysByPid`, `keysByHash`, `reapplying`)
3. Demultiplexes AX notifications by type and dispatches to different handlers
4. Handles tab swapping, fullscreen detection, and window removal
5. Owns the `DragReapplyScheduler`

This stage decomposes it into:
- **5 typed observers** (one per AX notification type) that share a single AXObserver per PID
- **`WindowEventRouter`** — receives raw AX callbacks and routes to the correct typed observer
- **`WindowTracker`** — takes over the tracking state (`elements`, `keysByHash`, `keysByPid`, `reapplying`, `observers`) currently on `ResizeObserver`

---

## Architecture note: shared AXObserver per PID

AXObserver is a per-PID resource. The current `ResizeObserver` creates one AXObserver per PID and registers all 5 notification types on it. The new design keeps this — `WindowEventRouter` owns the per-PID AXObserver instances and routes incoming notifications to the appropriate typed observer.

Each typed observer does NOT create its own AXObserver. Instead, `WindowEventRouter.observe(window:pid:key:)` registers all notifications and `WindowEventRouter.stopObserving(key:pid:)` unregisters them. The C callback in `WindowEventRouter` dispatches to the correct observer based on the notification name.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Events/WindowMovedEvent.swift` | **New file** |
| `UnnamedWindowManager/Events/WindowResizedEvent.swift` | **New file** |
| `UnnamedWindowManager/Events/WindowMiniaturizedEvent.swift` | **New file** |
| `UnnamedWindowManager/Events/WindowDestroyedEvent.swift` | **New file** |
| `UnnamedWindowManager/Events/WindowTitleChangedEvent.swift` | **New file** |
| `UnnamedWindowManager/Observers/WindowMovedObserver.swift` | **New file** |
| `UnnamedWindowManager/Observers/WindowResizedObserver.swift` | **New file** |
| `UnnamedWindowManager/Observers/WindowMiniaturizedObserver.swift` | **New file** |
| `UnnamedWindowManager/Observers/WindowDestroyedObserver.swift` | **New file** |
| `UnnamedWindowManager/Observers/WindowTitleChangedObserver.swift` | **New file** |
| `UnnamedWindowManager/Observers/WindowEventRouter.swift` | **New file** — demuxes AX callbacks |
| `UnnamedWindowManager/Services/Observation/WindowTracker.swift` | **New file** — tracking state extracted from ResizeObserver |
| `UnnamedWindowManager/Services/Observation/ResizeObserver.swift` | **Delete** |
| `UnnamedWindowManager/Services/Observation/AXCallback.swift` | **Delete** |
| `UnnamedWindowManager/Services/Observation/DragReapplyScheduler.swift` | Modify — reference `WindowTracker` instead of `ResizeObserver` |
| `UnnamedWindowManager/Services/Observation/SwapOverlay.swift` | No change (if only used by DragReapplyScheduler) |
| `UnnamedWindowManager/Services/Window/AnimationService.swift` | Modify — reference `WindowTracker.shared.reapplying` |
| `UnnamedWindowManager/Services/Scrolling/ScrollingAnimationService.swift` | Modify — reference `WindowTracker.shared.reapplying` |
| `UnnamedWindowManager/Services/Window/FocusedWindowBorderService.swift` | Modify — reference `WindowTracker` if it reads `elements` |
| `UnnamedWindowManager/Services/ReapplyHandler.swift` | Modify — reference `WindowTracker.shared.reapplying` |
| All files referencing `ResizeObserver.shared` | Modify — update to `WindowTracker.shared` or appropriate observer |

---

## Implementation Steps

### 1. Create event structs

All per-window events carry the window identity:

```swift
struct WindowMovedEvent: AppEvent {
    let key: WindowSlot
    let element: AXUIElement
    let pid: pid_t
}

struct WindowResizedEvent: AppEvent {
    let key: WindowSlot
    let element: AXUIElement
    let pid: pid_t
    let isFullScreen: Bool
}

struct WindowMiniaturizedEvent: AppEvent {
    let key: WindowSlot
    let pid: pid_t
}

struct WindowDestroyedEvent: AppEvent {
    let key: WindowSlot
    let pid: pid_t
}

struct WindowTitleChangedEvent: AppEvent {
    let key: WindowSlot
    let pid: pid_t
}
```

### 2. Create WindowTracker

Extract the tracking state from `ResizeObserver` into a focused service:

```swift
// Tracks the mapping between WindowSlots, AXUIElements, and PIDs for all tiled/scrolled windows.
// Central registry for window identity and observation state.
final class WindowTracker {
    static let shared = WindowTracker()
    private init() {}

    var elements:   [WindowSlot: AXUIElement]    = [:]
    var keysByPid:  [pid_t: Set<WindowSlot>]     = [:]
    var keysByHash: [UInt: WindowSlot]            = [:]
    var reapplying: Set<WindowSlot>               = []

    private(set) lazy var reapplyScheduler = DragReapplyScheduler(tracker: self)

    func register(key: WindowSlot, element: AXUIElement, pid: pid_t) {
        elements[key] = element
        keysByPid[pid, default: []].insert(key)
        keysByHash[key.windowHash] = key
    }

    func window(for key: WindowSlot) -> AXUIElement? {
        elements[key]
    }

    func cleanup(key: WindowSlot, pid: pid_t) {
        reapplyScheduler.cancel(key: key)
        reapplyScheduler.overlay.hide()
        reapplying.remove(key)
        elements.removeValue(forKey: key)
        keysByHash.removeValue(forKey: key.windowHash)
        keysByPid[pid]?.remove(key)
        LayoutService.shared.clearCache(for: key)
        ScrollingLayoutService.shared.clearCache(for: key)
    }
}
```

### 3. Create WindowEventRouter

This replaces the per-PID AXObserver management from `ResizeObserver` and the C callback from `AXCallback.swift`:

```swift
// Creates per-PID AXObserver instances, registers per-window AX notifications,
// and routes callbacks to the appropriate typed observer.
final class WindowEventRouter {
    static let shared = WindowEventRouter()
    private init() {}

    private var observers: [pid_t: AXObserver] = [:]

    func observe(window: AXUIElement, pid: pid_t, key: WindowSlot) {
        guard WindowTracker.shared.elements[key] == nil else { return }
        WindowTracker.shared.register(key: key, element: window, pid: pid)

        guard let axObs = axObserver(for: pid) else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(axObs, window, kAXWindowMovedNotification as CFString, refcon)
        AXObserverAddNotification(axObs, window, kAXWindowResizedNotification as CFString, refcon)
        AXObserverAddNotification(axObs, window, kAXWindowMiniaturizedNotification as CFString, refcon)
        AXObserverAddNotification(axObs, window, "AXUIElementDestroyed" as CFString, refcon)
        AXObserverAddNotification(axObs, window, "AXTitleChanged" as CFString, refcon)
        // Tab sibling observation (same as current ResizeObserver.observe)
    }

    func stopObserving(key: WindowSlot, pid: pid_t) {
        guard let window = WindowTracker.shared.elements[key],
              let axObs = observers[pid] else { return }
        // Remove all 5 notifications
        AXObserverRemoveNotification(axObs, window, kAXWindowMovedNotification as CFString)
        AXObserverRemoveNotification(axObs, window, kAXWindowResizedNotification as CFString)
        AXObserverRemoveNotification(axObs, window, kAXWindowMiniaturizedNotification as CFString)
        AXObserverRemoveNotification(axObs, window, "AXUIElementDestroyed" as CFString)
        AXObserverRemoveNotification(axObs, window, "AXTitleChanged" as CFString)
        WindowTracker.shared.cleanup(key: key, pid: pid)
        cleanupPidIfEmpty(pid)
    }

    func handle(element: AXUIElement, notification: String, pid: pid_t) {
        // Resolve key (same logic as current ResizeObserver.handle)
        let tracker = WindowTracker.shared
        let resolvedKey: WindowSlot? = /* same resolution logic */

        guard let key = resolvedKey else { return }

        switch notification {
        case kAXWindowMovedNotification as String:
            WindowMovedObserver.shared.notify(WindowMovedEvent(key: key, element: element, pid: pid))
        case kAXWindowResizedNotification as String:
            let isFullScreen = /* same check as current */
            WindowResizedObserver.shared.notify(WindowResizedEvent(key: key, element: element, pid: pid, isFullScreen: isFullScreen))
        case "AXUIElementDestroyed":
            WindowDestroyedObserver.shared.notify(WindowDestroyedEvent(key: key, pid: pid))
        case kAXWindowMiniaturizedNotification as String:
            WindowMiniaturizedObserver.shared.notify(WindowMiniaturizedEvent(key: key, pid: pid))
        case "AXTitleChanged":
            WindowTitleChangedObserver.shared.notify(WindowTitleChangedEvent(key: key, pid: pid))
        default: break
        }
    }

    // Tab swap logic (swapTab from current ResizeObserver) also lives here
    func swapTab(oldKey: WindowSlot, newWindow: AXUIElement, newHash: UInt) {
        // Same logic as current ResizeObserver.swapTab, using WindowTracker for state
    }

    // Private: axObserver(for:), cleanupPidIfEmpty — same as current ResizeObserver
}
```

### 4. Create typed observers

These are thin wrappers — they don't manage AX registration (that's `WindowEventRouter`'s job). They just hold subscriptions:

```swift
// Notifies subscribers when a tracked window is moved by the user or system.
final class WindowMovedObserver: EventObserver<WindowMovedEvent> {
    static let shared = WindowMovedObserver()
}

// (same pattern for all 5)
```

### 5. Register handler subscribers

The current handler logic from `ResizeObserver.handle()` (lines 129–193) becomes subscribers. Register in `UnnamedWindowManagerApp.init()` or a dedicated setup function:

```swift
WindowDestroyedObserver.shared.subscribe { event in
    let isScrolling = ScrollingRootStore.shared.isTracked(event.key)
    removeWindow(key: event.key, pid: event.pid, isScrolling: isScrolling)
}

WindowMiniaturizedObserver.shared.subscribe { event in
    let isScrolling = ScrollingRootStore.shared.isTracked(event.key)
    removeWindow(key: event.key, pid: event.pid, isScrolling: isScrolling)
}

WindowResizedObserver.shared.subscribe { event in
    if event.isFullScreen {
        let isScrolling = ScrollingRootStore.shared.isTracked(event.key)
        removeWindow(key: event.key, pid: event.pid, isScrolling: isScrolling)
        return
    }
    handleMoveOrResize(key: event.key, element: event.element, isResize: true)
}

WindowMovedObserver.shared.subscribe { event in
    handleMoveOrResize(key: event.key, element: event.element, isResize: false)
}

WindowTitleChangedObserver.shared.subscribe { _ in
    // No-op (matches current behavior)
}
```

The shared `handleMoveOrResize` and `removeWindow` helper functions are extracted into a service or free functions.

### 6. Update all ResizeObserver.shared references

Search the entire codebase for `ResizeObserver.shared` and update:
- `.elements[key]` → `WindowTracker.shared.elements[key]`
- `.keysByHash[hash]` → `WindowTracker.shared.keysByHash[hash]`
- `.keysByPid[pid]` → `WindowTracker.shared.keysByPid[pid]`
- `.reapplying` → `WindowTracker.shared.reapplying`
- `.observe(window:pid:key:)` → `WindowEventRouter.shared.observe(window:pid:key:)`
- `.stopObserving(key:pid:)` → `WindowEventRouter.shared.stopObserving(key:pid:)`
- `.swapTab(...)` → `WindowEventRouter.shared.swapTab(...)`
- `.window(for:)` → `WindowTracker.shared.window(for:)`
- `.reapplyScheduler` → `WindowTracker.shared.reapplyScheduler`
- `.cleanup(key:pid:)` → `WindowTracker.shared.cleanup(key:pid:)` (called from `WindowEventRouter.stopObserving`)

**Key files to update (non-exhaustive — grep for `ResizeObserver.shared`):**
- `AnimationService.swift` — `reapplying`
- `ScrollingAnimationService.swift` — `reapplying`
- `ReapplyHandler.swift` — `reapplying`
- `DragReapplyScheduler.swift` — `observer` reference → `tracker`
- `FocusChangeHandler.swift` (from stage 4) — `keysByHash`, `swapTab`
- `TileHandler.swift`, `ScrollHandler.swift`, etc. — `observe`, `elements`

### 7. Delete old files

- Delete `Services/Observation/ResizeObserver.swift`
- Delete `Services/Observation/AXCallback.swift`

---

## Key Technical Notes

- The C callback in `WindowEventRouter` must be a free function (same constraint as before). It receives `Unmanaged<WindowEventRouter>` via refcon.
- Key resolution logic (lines 129–148 of current `ResizeObserver.handle`) handles destroyed elements where `windowID()` fails — this must be preserved in `WindowEventRouter.handle()`.
- The tab swap detection in `handle()` (lines 135–144) fires `swapTab` + `ReapplyHandler.reapplyAll()` when an untracked tab sibling is detected — this stays in `WindowEventRouter.handle()` before dispatching to observers, since it's a routing decision, not a subscriber concern.
- `WindowTracker.reapplying` is mutated from multiple places (animation services on render thread, observers on main thread). Currently this is safe because the set is only accessed on main thread despite animation ticks running on the render thread — the `DispatchQueue.main.async` in animation completion ensures main-thread access. This must remain true.
- `DragReapplyScheduler` currently takes a weak `ResizeObserver` reference. Change to weak `WindowTracker` reference. The `elements` dictionary access in `updateDragOverlay` reads from `WindowTracker.shared.elements`.
- The `WindowEventRouter` replaces both `ResizeObserver.axObserver(for:)` and `AXCallback.axNotificationCallback`. The per-PID AXObserver cleanup on last-window-removed must be preserved (`cleanupPidIfEmpty`).

---

## Verification

1. Build — no errors
2. Tile windows → they snap to layout
3. Drag a tiled window → drop overlay appears, reapply fires on mouse-up
4. Resize a tiled window → layout recalculates proportions
5. Close a tiled window → layout reflows to fill the gap
6. Minimize a tiled window → removed from layout
7. Enter fullscreen → window removed from tiling
8. Tab switching in Safari → tab swap detection works
9. Animation plays smoothly during tiling operations
10. Grep codebase for `ResizeObserver` — no remaining references
