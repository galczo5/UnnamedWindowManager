# Plan: 03_app_lifecycle_events — AppActivated and AppTerminated observers

## Checklist

- [x] Create `AppActivatedEvent` in `Events/`
- [x] Create `AppActivatedObserver` in `Observers/`
- [x] Create `AppTerminatedEvent` in `Events/`
- [x] Create `AppTerminatedObserver` in `Observers/`
- [x] Refactor `WindowCreationObserver` to subscribe to `AppActivatedObserver` and `AppTerminatedObserver`
- [x] Refactor `FocusObserver` to subscribe to `AppActivatedObserver` and `AppTerminatedObserver`
- [x] Start `AppActivatedObserver` and `AppTerminatedObserver` in `UnnamedWindowManagerApp.init()`
- [x] Verify build and all functionality

---

## Context / Problem

Both `WindowCreationObserver` and `FocusObserver` independently register their own `NSWorkspace.didActivateApplicationNotification` and `NSWorkspace.didTerminateApplicationNotification` observers. This duplicates the observation mechanism and means two separate `@objc` methods fire for each app activation/termination.

This stage extracts app lifecycle events into dedicated observers. `WindowCreationObserver` and `FocusObserver` become subscribers rather than direct NSWorkspace observers for these events.

**Current duplication:**
- `WindowCreationObserver.start()` lines 51–55: registers `didActivateApp` and `didTerminateApp`
- `FocusObserver.start()` lines 37–41: registers `didActivateApp` and `didTerminateApp`

Both do the same thing: call `observerManager?.observeApp(pid:)` on activate and `observerManager?.removeAppObserver(pid:)` on terminate. The only difference is `FocusObserver` also posts `windowFocusChanged` and calls `applyDim` on activation.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Events/AppActivatedEvent.swift` | **New file** — event carrying the activated app |
| `UnnamedWindowManager/Observers/AppActivatedObserver.swift` | **New file** — wraps NSWorkspace.didActivateApplicationNotification |
| `UnnamedWindowManager/Events/AppTerminatedEvent.swift` | **New file** — event carrying the terminated app |
| `UnnamedWindowManager/Observers/AppTerminatedObserver.swift` | **New file** — wraps NSWorkspace.didTerminateApplicationNotification |
| `UnnamedWindowManager/Services/Observation/WindowCreationObserver.swift` | Modify — remove NSWorkspace observers, subscribe to new observers |
| `UnnamedWindowManager/Services/Observation/FocusObserver.swift` | Modify — remove NSWorkspace observers, subscribe to new observers |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — start AppActivatedObserver and AppTerminatedObserver |

---

## Implementation Steps

### 1. AppActivated event + observer

```swift
struct AppActivatedEvent: AppEvent {
    let app: NSRunningApplication
}
```

```swift
// Observes NSWorkspace app activation and notifies subscribers with the activated app.
final class AppActivatedObserver: EventObserver<AppActivatedEvent> {
    static let shared = AppActivatedObserver()

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didActivateApp(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func didActivateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        notify(AppActivatedEvent(app: app))
    }
}
```

### 2. AppTerminated event + observer

```swift
struct AppTerminatedEvent: AppEvent {
    let app: NSRunningApplication
}
```

```swift
// Observes NSWorkspace app termination and notifies subscribers with the terminated app.
final class AppTerminatedObserver: EventObserver<AppTerminatedEvent> {
    static let shared = AppTerminatedObserver()

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didTerminateApp(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func didTerminateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        notify(AppTerminatedEvent(app: app))
    }
}
```

### 3. Refactor WindowCreationObserver

Remove the NSWorkspace observer registrations from `start()` (lines 51–55). Replace with subscriptions:

```swift
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
    WindowFocusChangedObserver.shared.subscribe { _ in
        AutoModeHandler.handleFocusChange()
    }

    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        observerManager?.observeApp(pid: app.processIdentifier)
    }
}
```

Remove the `@objc didActivateApp`, `@objc didTerminateApp`, and `@objc handleWindowFocusChanged` methods entirely.

### 4. Refactor FocusObserver

Remove the NSWorkspace observer registrations from `start()` (lines 37–41). Replace with subscriptions:

```swift
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
        WindowFocusChangedObserver.shared.notify(WindowFocusChangedEvent())
        self?.applyDim(pid: pid)
    }
    AppTerminatedObserver.shared.subscribe { [weak self] event in
        self?.observerManager?.removeAppObserver(pid: event.app.processIdentifier)
    }

    if let app = NSWorkspace.shared.frontmostApplication {
        observerManager?.observeApp(pid: app.processIdentifier)
        applyDim(pid: app.processIdentifier)
    }
}
```

Remove the `@objc didActivateApp` and `@objc didTerminateApp` methods entirely.

### 5. Update UnnamedWindowManagerApp.init()

Add before existing observer starts:

```swift
AppActivatedObserver.shared.start()
AppTerminatedObserver.shared.start()
```

These must start **before** `FocusObserver.shared.start()` and `WindowCreationObserver.shared.start()` so subscriptions are active when those observers initialize with the frontmost app.

---

## Key Technical Notes

- `AppActivatedObserver` and `AppTerminatedObserver` extract the `NSRunningApplication` from the notification userInfo — subscribers receive a typed event, not a raw notification.
- The subscription order matters for `AppActivatedObserver`: `FocusObserver`'s subscriber calls `observeApp` + `applyDim`, and `WindowCreationObserver`'s subscriber calls `observeApp`. Both need the AXObserver registered before any AX notifications can fire, so `observeApp` must complete first. Since subscriptions are called in order and all on main thread, this is safe.
- `FocusObserver`'s activate handler still posts `WindowFocusChangedEvent` — this was the behavior before (line 53 of original). The ordering is: app activated → AX observer registered → focus changed notification posted → dim applied.
- `AppObserverManager` is still used internally by `WindowCreationObserver` and `FocusObserver` for managing per-app AXObserver instances. It will be further refactored in stage 4.

---

## Verification

1. Build — no errors
2. Open a new app (e.g. Terminal) → window creation observer registers AX observer for it
3. Quit an app → AX observers cleaned up, no crashes
4. Switch between apps → focus dimming applies correctly
5. Auto mode enabled → new windows tile on app activation
6. Confirm no remaining `didActivateApplicationNotification` / `didTerminateApplicationNotification` registrations outside of `AppActivatedObserver` / `AppTerminatedObserver`
