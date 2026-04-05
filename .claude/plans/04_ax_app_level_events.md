# Plan: 04_ax_app_level_events — WindowCreated and FocusedWindowChanged observers

## Checklist

- [ ] Create `WindowCreatedEvent` in `Events/`
- [ ] Create `WindowCreatedObserver` in `Observers/`
- [ ] Create `FocusedWindowChangedEvent` in `Events/`
- [ ] Create `FocusedWindowChangedObserver` in `Observers/`
- [ ] Migrate window creation handling to subscribe to `WindowCreatedObserver`
- [ ] Migrate focus/dim handling to subscribe to `FocusedWindowChangedObserver`
- [ ] Delete `Services/Observation/WindowCreationObserver.swift`
- [ ] Delete `Services/Observation/FocusObserver.swift`
- [ ] Refactor `AppObserverManager` into the new observers or keep as shared utility
- [ ] Update `UnnamedWindowManagerApp.init()` startup sequence
- [ ] Verify build and all functionality

---

## Context / Problem

The current `WindowCreationObserver` and `FocusObserver` are app-level AXObserver wrappers — they register `kAXWindowCreatedNotification`, `kAXFocusedWindowChangedNotification`, and `kAXMainWindowChangedNotification` on the application-level AXUIElement for every running app.

After stage 3, these observers already subscribe to `AppActivatedObserver`/`AppTerminatedObserver` for their app lifecycle needs. This stage replaces the observers themselves with the new pattern:

- `WindowCreatedObserver` — fires `WindowCreatedEvent` when any app creates a window
- `FocusedWindowChangedObserver` — fires `FocusedWindowChangedEvent` when the focused window changes

The complex handler logic (auto-mode routing, tab detection, dimming) moves into subscribers.

---

## AXObserver management note

Both current observers use `AppObserverManager` to create per-app AXObserver instances. Each new observer will need its own `AppObserverManager` (or equivalent internal mechanism) because they register different AX notification types:
- `WindowCreatedObserver`: `kAXWindowCreatedNotification`
- `FocusedWindowChangedObserver`: `kAXFocusedWindowChangedNotification`, `kAXMainWindowChangedNotification`

`AppObserverManager` remains as a shared utility class — it's a clean helper for per-app AXObserver lifecycle.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Events/WindowCreatedEvent.swift` | **New file** — event struct |
| `UnnamedWindowManager/Observers/WindowCreatedObserver.swift` | **New file** — AXObserver for kAXWindowCreated, subscribes to app lifecycle |
| `UnnamedWindowManager/Events/FocusedWindowChangedEvent.swift` | **New file** — event struct |
| `UnnamedWindowManager/Observers/FocusedWindowChangedObserver.swift` | **New file** — AXObserver for kAXFocusedWindowChanged/kAXMainWindowChanged |
| `UnnamedWindowManager/Services/Observation/WindowCreationObserver.swift` | **Delete** |
| `UnnamedWindowManager/Services/Observation/FocusObserver.swift` | **Delete** |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — start new observers, register handler subscribers |

---

## Implementation Steps

### 1. WindowCreated event + observer

```swift
struct WindowCreatedEvent: AppEvent {
    let window: AXUIElement
    let pid: pid_t
    let appName: String
    let title: String
    let windowHash: UInt?
}
```

The observer manages per-app AXObserver instances for `kAXWindowCreatedNotification`. On app activation it starts observing; on termination it stops. The C callback extracts window metadata and calls `notify()`.

```swift
// Observes kAXWindowCreatedNotification for every active app and fires WindowCreatedEvent.
final class WindowCreatedObserver: EventObserver<WindowCreatedEvent> {
    static let shared = WindowCreatedObserver()
    private var observerManager: AppObserverManager?

    func start() {
        observerManager = AppObserverManager(
            callback: windowCreatedCallback,
            notifications: [kAXWindowCreatedNotification as CFString],
            refcon: Unmanaged.passUnretained(self).toOpaque())

        AppActivatedObserver.shared.subscribe { [weak self] event in
            self?.observerManager?.observeApp(pid: event.app.processIdentifier)
        }
        AppTerminatedObserver.shared.subscribe { [weak self] event in
            self?.observerManager?.removeAppObserver(pid: event.app.processIdentifier)
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observerManager?.observeApp(pid: app.processIdentifier)
        }
    }
}
```

The C callback (currently at the top of `WindowCreationObserver.swift`) moves into this file, simplified to extract data and call `notify`:

```swift
private func windowCreatedCallback(
    _ observer: AXObserver, _ element: AXUIElement,
    _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    DispatchQueue.main.async {
        guard let refcon else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "unknown"
        var titleRef: CFTypeRef?
        let title = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success
            ? (titleRef as? String ?? "") : ""
        let wid = windowID(of: element).map(UInt.init)

        let obs = Unmanaged<WindowCreatedObserver>.fromOpaque(refcon).takeUnretainedValue()
        obs.notify(WindowCreatedEvent(window: element, pid: pid, appName: appName,
                                       title: title, windowHash: wid))
    }
}
```

The current handler logic (logging + `AutoModeHandler.handleFocusChange()`) becomes a subscriber in `UnnamedWindowManagerApp.init()`:

```swift
WindowCreatedObserver.shared.subscribe { event in
    let label = event.title.isEmpty ? event.appName : "\(event.appName) – \(event.title)"
    let key = windowSlot(for: event.window, pid: event.pid)
    let rootDesc: String = /* same root lookup logic as current */
    Logger.shared.log("window appeared \"\(label)\" pid=\(event.pid) wid=\(event.windowHash ?? 0) root=\(rootDesc)")
    AutoModeHandler.handleFocusChange()
}
```

### 2. FocusedWindowChanged event + observer

```swift
struct FocusedWindowChangedEvent: AppEvent {
    let pid: pid_t
}
```

The observer manages per-app AXObserver instances for `kAXFocusedWindowChangedNotification` and `kAXMainWindowChangedNotification`:

```swift
// Observes AX focus changes across all apps and fires FocusedWindowChangedEvent.
final class FocusedWindowChangedObserver: EventObserver<FocusedWindowChangedEvent> {
    static let shared = FocusedWindowChangedObserver()
    private var observerManager: AppObserverManager?

    func start() {
        observerManager = AppObserverManager(
            callback: focusChangedCallback,
            notifications: [
                kAXFocusedWindowChangedNotification as CFString,
                kAXMainWindowChangedNotification    as CFString,
            ],
            refcon: Unmanaged.passUnretained(self).toOpaque())

        AppActivatedObserver.shared.subscribe { [weak self] event in
            let pid = event.app.processIdentifier
            self?.observerManager?.observeApp(pid: pid)
            // App activation counts as a focus change
            self?.notify(FocusedWindowChangedEvent(pid: pid))
        }
        AppTerminatedObserver.shared.subscribe { [weak self] event in
            self?.observerManager?.removeAppObserver(pid: event.app.processIdentifier)
        }

        if let app = NSWorkspace.shared.frontmostApplication {
            observerManager?.observeApp(pid: app.processIdentifier)
            notify(FocusedWindowChangedEvent(pid: app.processIdentifier))
        }
    }
}
```

C callback:

```swift
private func focusChangedCallback(
    _ observer: AXObserver, _ element: AXUIElement,
    _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let obs = Unmanaged<FocusedWindowChangedObserver>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        obs.notify(FocusedWindowChangedEvent(pid: pid))
    }
}
```

### 3. Move FocusObserver handler logic into subscribers

The complex `applyDim` logic from `FocusObserver` (tab detection, dimming, border, scroll-to-center) needs a home. Create a new service or register it as a subscriber. Since it's substantial (90+ lines with retry logic), extract it into a dedicated handler:

Create `Services/Window/FocusChangeHandler.swift`:

```swift
// Handles focus change effects: window dimming, tab detection, border updates, scroll-to-center.
final class FocusChangeHandler {
    static let shared = FocusChangeHandler()
    private var retryWorkItem: DispatchWorkItem?

    func handleFocusChange(pid: pid_t) {
        // Move the entire applyDim logic from FocusObserver here unchanged
    }
}
```

Register as subscriber in `UnnamedWindowManagerApp.init()`:

```swift
FocusedWindowChangedObserver.shared.subscribe { event in
    WindowFocusChangedObserver.shared.notify(WindowFocusChangedEvent())
    FocusChangeHandler.shared.handleFocusChange(pid: event.pid)
}
```

### 4. Update UnnamedWindowManagerApp.init()

Start order:

```swift
AppActivatedObserver.shared.start()
AppTerminatedObserver.shared.start()
FocusedWindowChangedObserver.shared.start()
ScreenParametersChangedObserver.shared.start()
SpaceChangedObserver.shared.start()
WindowCreatedObserver.shared.start()
```

Register subscribers for handler logic after starting observers.

### 5. Delete old files

- Delete `Services/Observation/WindowCreationObserver.swift`
- Delete `Services/Observation/FocusObserver.swift`

---

## Key Technical Notes

- The C callbacks must be free functions (not closures) — they cannot capture Swift context. The `refcon` pattern (passing `Unmanaged<Self>`) is preserved.
- `FocusedWindowChangedObserver` fires on both AX focus change AND app activation. This matches the current behavior where `FocusObserver.didActivateApp` manually calls `applyDim`.
- The `FocusChangeHandler` retains the `retryWorkItem` for tab detection polling — this state was previously on `FocusObserver` and must be preserved.
- `WindowFocusChangedObserver.notify()` (the internal event from stage 2) is called from the `FocusedWindowChangedObserver` subscriber, not from the observer itself. This preserves the current two-level event flow: AX event → internal notification.
- `AppObserverManager` remains in `Services/Observation/` — it's a utility used by both new observers.

---

## Verification

1. Build — no errors
2. Open new app windows → logged in console with "window appeared" 
3. Auto mode on → new windows tile automatically
4. Click between windows → dimming applies to inactive windows
5. Tab switching in Safari/Terminal → tab swap detection works, layout preserved
6. Focus a scrolling-root side window → auto-scrolls to center
7. Focus border appears on focused tiled/scrolled window
8. Quit apps → no crashes, observers cleaned up
