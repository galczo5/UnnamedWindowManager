# Plan: 02_workspace_and_internal_events — Migrate simple NSWorkspace and internal NotificationCenter events

## Checklist

- [ ] Create `ScreenParametersChangedEvent` in `Events/`
- [ ] Create `ScreenParametersChangedObserver` in `Observers/`
- [ ] Migrate `ScreenChangeObserver` consumers to subscribe to `ScreenParametersChangedObserver`
- [ ] Delete `Services/Observation/ScreenChangeObserver.swift`
- [ ] Create `SpaceChangedEvent` in `Events/`
- [ ] Create `SpaceChangedObserver` in `Observers/`
- [ ] Migrate `SpaceChangeObserver` consumers to subscribe to `SpaceChangedObserver`
- [ ] Delete `Services/Observation/SpaceChangeObserver.swift`
- [ ] Create `TileStateChangedEvent` in `Events/`
- [ ] Create `TileStateChangedObserver` in `Observers/`
- [ ] Migrate `ReapplyHandler` and `UnnamedWindowManagerApp` to use `TileStateChangedObserver`
- [ ] Create `WindowFocusChangedEvent` in `Events/`
- [ ] Create `WindowFocusChangedObserver` in `Observers/`
- [ ] Migrate `FocusObserver`, `WindowCreationObserver`, and `UnnamedWindowManagerApp` to use `WindowFocusChangedObserver`
- [ ] Remove `Notification.Name` extensions for `tileStateChanged` and `windowFocusChanged`
- [ ] Update `UnnamedWindowManagerApp.init()` to start new observers
- [ ] Verify build and all functionality

---

## Context / Problem

Four of the current event sources are simple 1:1 notification → handler patterns with no per-element registration. They are the easiest to migrate and will validate the new observer infrastructure end-to-end.

**Current sources:**
- `ScreenChangeObserver` — listens to `NSApplication.didChangeScreenParametersNotification`
- `SpaceChangeObserver` — listens to `NSWorkspace.activeSpaceDidChangeNotification`
- `ReapplyHandler` → posts `tileStateChanged` via `NotificationCenter`
- `FocusObserver` → posts `windowFocusChanged` via `NotificationCenter`

After this stage, all four use the new `EventObserver` pub/sub pattern and the old `Notification.Name` extensions are removed.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Events/ScreenParametersChangedEvent.swift` | **New file** — event struct |
| `UnnamedWindowManager/Observers/ScreenParametersChangedObserver.swift` | **New file** — wraps NSApplication.didChangeScreenParametersNotification |
| `UnnamedWindowManager/Events/SpaceChangedEvent.swift` | **New file** — event struct |
| `UnnamedWindowManager/Observers/SpaceChangedObserver.swift` | **New file** — wraps NSWorkspace.activeSpaceDidChangeNotification, contains displaced-window logic |
| `UnnamedWindowManager/Events/TileStateChangedEvent.swift` | **New file** — event struct |
| `UnnamedWindowManager/Observers/TileStateChangedObserver.swift` | **New file** — replaces NotificationCenter tileStateChanged |
| `UnnamedWindowManager/Events/WindowFocusChangedEvent.swift` | **New file** — event struct |
| `UnnamedWindowManager/Observers/WindowFocusChangedObserver.swift` | **New file** — replaces NotificationCenter windowFocusChanged |
| `UnnamedWindowManager/Services/ReapplyHandler.swift` | Modify — post via `TileStateChangedObserver.shared.notify()` instead of NotificationCenter |
| `UnnamedWindowManager/Services/Observation/FocusObserver.swift` | Modify — post via `WindowFocusChangedObserver.shared.notify()` instead of NotificationCenter |
| `UnnamedWindowManager/Services/Observation/WindowCreationObserver.swift` | Modify — subscribe to `WindowFocusChangedObserver` instead of NotificationCenter |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — subscribe to new observers instead of `.onReceive(NotificationCenter...)`, start new observers, remove Notification.Name extensions |
| `UnnamedWindowManager/Services/Observation/ScreenChangeObserver.swift` | **Delete** |
| `UnnamedWindowManager/Services/Observation/SpaceChangeObserver.swift` | **Delete** |

---

## Implementation Steps

### 1. ScreenParametersChanged event + observer

The event is empty (no payload — the handler reads current screen state):

```swift
struct ScreenParametersChangedEvent: AppEvent {}
```

The observer wraps NSApplication notification and contains the handler logic currently in `ScreenChangeObserver.screenParametersChanged()`:

```swift
final class ScreenParametersChangedObserver: EventObserver<ScreenParametersChangedEvent> {
    static let shared = ScreenParametersChangedObserver()

    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screenParametersChanged() {
        notify(ScreenParametersChangedEvent())
    }
}
```

The handler logic that currently lives in `ScreenChangeObserver.screenParametersChanged()` (clearing caches, recomputing sizes, updating wallpaper, reapplying layout) moves into a subscriber registered in `UnnamedWindowManagerApp.init()`:

```swift
ScreenParametersChangedObserver.shared.subscribe { _ in
    guard let screen = NSScreen.main else { return }
    LayoutService.shared.clearCache()
    ScrollingLayoutService.shared.clearCache()
    TilingEditService.shared.recomputeVisibleRootSizes(screen: screen)
    WallpaperService.shared.screenChanged()
    ReapplyHandler.reapplyAll()
}
```

### 2. SpaceChanged event + observer

```swift
struct SpaceChangedEvent: AppEvent {}
```

The observer wraps `NSWorkspace.activeSpaceDidChangeNotification`. The displaced-window detection logic (`untileDisplacedWindows`, `displacedWindows`, `allWindowSlots`) currently in `SpaceChangeObserver` moves into the new `SpaceChangedObserver` class since it's tightly coupled to the observation lifecycle (needs `lastTilingRootID`/`lastScrollingRootID` state). The root-tracking/logging logic also stays inside the observer.

The key change: the observer calls `notify(SpaceChangedEvent())` after performing its internal bookkeeping, and external consumers (like the menu state refresh in `UnnamedWindowManagerApp`) subscribe.

```swift
final class SpaceChangedObserver: EventObserver<SpaceChangedEvent> {
    static let shared = SpaceChangedObserver()
    private var lastTilingRootID: UUID?
    private var lastScrollingRootID: UUID?

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @objc private func activeSpaceDidChange() {
        OnScreenWindowCache.invalidate()
        untileDisplacedWindows()
        ReapplyHandler.reapplyAll()
        // ... root tracking logic (same as current) ...
        notify(SpaceChangedEvent())
    }

    // Private helpers: untileDisplacedWindows, displacedWindows, allWindowSlots
    // (moved from current SpaceChangeObserver unchanged)
}
```

### 3. TileStateChanged event + observer

```swift
struct TileStateChangedEvent: AppEvent {}
```

Observer is a pure pub/sub relay — no platform observation. `ReapplyHandler` calls `notify()` directly:

```swift
final class TileStateChangedObserver: EventObserver<TileStateChangedEvent> {
    static let shared = TileStateChangedObserver()
}
```

In `ReapplyHandler.reapplyAll()` line 80–81, replace:
```swift
// Before:
NotificationCenter.default.post(name: .tileStateChanged, object: nil)
// After:
TileStateChangedObserver.shared.notify(TileStateChangedEvent())
```

### 4. WindowFocusChanged event + observer

```swift
struct WindowFocusChangedEvent: AppEvent {}
```

Same pure relay pattern:

```swift
final class WindowFocusChangedObserver: EventObserver<WindowFocusChangedEvent> {
    static let shared = WindowFocusChangedObserver()
}
```

Replace posts in `FocusObserver` (lines 16 and 53):
```swift
// Before:
NotificationCenter.default.post(name: .windowFocusChanged, object: nil)
// After:
WindowFocusChangedObserver.shared.notify(WindowFocusChangedEvent())
```

Replace subscription in `WindowCreationObserver.start()` (line 57–58):
```swift
// Before:
NotificationCenter.default.addObserver(self, selector: #selector(handleWindowFocusChanged),
                                       name: .windowFocusChanged, object: nil)
// After:
WindowFocusChangedObserver.shared.subscribe { [weak self] _ in
    self?.handleWindowFocusChanged()
}
```

(Make `handleWindowFocusChanged` non-`@objc` private method.)

### 5. Update UnnamedWindowManagerApp

- Remove `Notification.Name` extensions (lines 6–9)
- Start `ScreenParametersChangedObserver.shared.start()` and subscribe handler
- Start `SpaceChangedObserver.shared.start()` (no subscriber needed in app — it handles itself)
- Subscribe to `TileStateChangedObserver` and `WindowFocusChangedObserver` for menu refresh
- Remove `.onReceive(NotificationCenter.default.publisher(for: .tileStateChanged))` (line 148)
- Remove `.onReceive(NotificationCenter.default.publisher(for: .windowFocusChanged))` (line 151)
- Remove `.onReceive(NSWorkspace...activeSpaceDidChangeNotification)` (line 154)

The menu refresh subscriptions registered in `init()`:
```swift
TileStateChangedObserver.shared.subscribe { [weak menuState] _ in
    menuState?.refresh()
}
WindowFocusChangedObserver.shared.subscribe { [weak menuState] _ in
    menuState?.refresh()
}
SpaceChangedObserver.shared.subscribe { [weak menuState] _ in
    menuState?.refresh()
}
```

Note: Since `.onReceive` is a SwiftUI view modifier and the subscriptions are now closures, the menu refresh must be triggered via the `@State` menuState which is `@Observable`. The subscribe closures call `menuState.refresh()` directly on the main thread — this works because all these events fire on the main thread.

### 6. Delete old files

- Delete `Services/Observation/ScreenChangeObserver.swift`
- Delete `Services/Observation/SpaceChangeObserver.swift`
- Remove from Xcode project

---

## Key Technical Notes

- `SpaceChangedObserver` retains internal state (`lastTilingRootID`, `lastScrollingRootID`) — this is observation-specific bookkeeping, not subscriber concern.
- `TileStateChangedObserver` and `WindowFocusChangedObserver` have no `start()` — they are pure relay hubs. Other code calls `notify()` directly.
- The `.onReceive` SwiftUI modifiers on the menu label view are replaced by closure subscriptions in `init()`. This is safe because `MenuState` is `@Observable` and SwiftUI will pick up changes via property observation.
- `ScreenParametersChangedObserver.screenParametersChanged()` fires on the main thread (NSApplication notification center delivers on the posting thread, which is main for system notifications).
- The `SpaceChangedObserver` must call `notify()` **after** `ReapplyHandler.reapplyAll()` and root-type updates, so subscribers see the settled state.

---

## Verification

1. Build — no errors
2. Plug/unplug external monitor or change resolution → layout reflows correctly
3. Switch spaces via Mission Control → windows untile if displaced, layout reflows, menu updates
4. Tile a window → menu shows "[tiled]" label
5. Focus different windows → menu state updates (frontmost tiled/scrolled status)
6. Confirm `ScreenChangeObserver.swift` and `SpaceChangeObserver.swift` are deleted
7. Confirm no remaining references to `Notification.Name.tileStateChanged` or `.windowFocusChanged`
