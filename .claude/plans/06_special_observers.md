# Plan: 06_special_observers — KeyDown, DisplayLinkTick, and WindowOcclusion observers

## Checklist

- [x] Create `KeyDownEvent` in `Events/`
- [x] Create `KeyDownObserver` in `Observers/`
- [x] Refactor `KeybindingService` to subscribe to `KeyDownObserver`
- [x] Create `DisplayLinkTickEvent` in `Events/`
- [x] Create `DisplayLinkTickObserver` in `Observers/`
- [x] Refactor `AnimationService` to subscribe to `DisplayLinkTickObserver`
- [x] Create `ScrollingDisplayLinkTickEvent` in `Events/`
- [x] Create `ScrollingDisplayLinkTickObserver` in `Observers/`
- [x] Refactor `ScrollingAnimationService` to subscribe to `ScrollingDisplayLinkTickObserver`
- [x] Create `WindowOcclusionChangedEvent` in `Events/`
- [x] Create `WindowOcclusionChangedObserver` in `Observers/`
- [x] Refactor `GifImageView` to use `WindowOcclusionChangedObserver`
- [x] Delete `Services/Observation/AppObserverManager.swift` if no longer referenced
- [x] Clean up `Services/Observation/` directory (remove if empty)
- [x] Update `CODE.md` to reflect new directory structure
- [x] Verify build and all functionality

---

## Context / Problem

Three observation mechanisms remain outside the new event system:
1. **CGEventTap** (`KeybindingService`) — global keyboard interception
2. **CVDisplayLink** (`AnimationService`, `ScrollingAnimationService`) — frame-synced animation ticks
3. **NSWindow notification** (`GifImageView`) — window occlusion state

These are the most "exotic" mechanisms and require design decisions about how the observer pattern maps to each.

---

## Design decisions

### KeyDown: event consumption pattern

The CGEventTap callback must return `nil` to consume a matched event or return the event to pass it through. This means `KeyDownObserver` needs a **consuming subscriber** pattern: subscribers return a `Bool` indicating whether they consumed the event. The first subscriber returning `true` stops the chain.

```swift
class ConsumingEventObserver<E: AppEvent> {
    typealias Handler = (E) -> Bool  // returns true if consumed

    func notify(_ event: E) -> Bool {
        for subscription in subscriptions {
            if subscription.handler(event) { return true }
        }
        return false
    }
}
```

### DisplayLinkTick: start/stop lifecycle

CVDisplayLink is expensive — it should only run when animations are active. The observer wraps the start/stop lifecycle. Subscribers call `start()` when they have work and the observer manages the CVDisplayLink. When no animations remain, the subscriber tells the observer to `stop()`.

Alternatively, the observer is always-on when started and ticks continuously. But this wastes CPU. Better: the observer exposes `startIfNeeded()` / `stopIfIdle()` matching the current pattern.

### WindowOcclusion: per-window subscription

Each `GifImageView` observes its own window's occlusion. The observer manages per-NSWindow subscriptions.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Events/KeyDownEvent.swift` | **New file** |
| `UnnamedWindowManager/Observers/KeyDownObserver.swift` | **New file** — wraps CGEventTap |
| `UnnamedWindowManager/Observers/ConsumingEventObserver.swift` | **New file** — base class for consuming pattern |
| `UnnamedWindowManager/Events/DisplayLinkTickEvent.swift` | **New file** |
| `UnnamedWindowManager/Observers/DisplayLinkTickObserver.swift` | **New file** — wraps CVDisplayLink for tiling |
| `UnnamedWindowManager/Events/ScrollingDisplayLinkTickEvent.swift` | **New file** |
| `UnnamedWindowManager/Observers/ScrollingDisplayLinkTickObserver.swift` | **New file** — wraps CVDisplayLink for scrolling |
| `UnnamedWindowManager/Events/WindowOcclusionChangedEvent.swift` | **New file** |
| `UnnamedWindowManager/Observers/WindowOcclusionChangedObserver.swift` | **New file** — wraps NSWindow occlusion |
| `UnnamedWindowManager/Services/Window/KeybindingService.swift` | Modify — delegate event tap to `KeyDownObserver`, subscribe for binding matching |
| `UnnamedWindowManager/Services/Window/AnimationService.swift` | Modify — subscribe to `DisplayLinkTickObserver`, remove internal CVDisplayLink management |
| `UnnamedWindowManager/Services/Scrolling/ScrollingAnimationService.swift` | Modify — subscribe to `ScrollingDisplayLinkTickObserver` |
| `UnnamedWindowManager/Services/Wallpaper/GifImageView.swift` | Modify — use `WindowOcclusionChangedObserver` |
| `UnnamedWindowManager/Services/Observation/AppObserverManager.swift` | **Delete** if no longer referenced (check after stages 3-4) |
| `UnnamedWindowManager/UnnamedWindowManager/CODE.md` | Modify — document new Events/ and Observers/ directories |

---

## Implementation Steps

### 1. ConsumingEventObserver base class

```swift
// Base class for observers where subscribers can consume events, stopping further propagation.
class ConsumingEventObserver<E: AppEvent> {
    struct Subscription {
        let id: UUID
        let handler: (E) -> Bool
    }

    private(set) var subscriptions: [Subscription] = []

    @discardableResult
    func subscribe(handler: @escaping (E) -> Bool) -> UUID {
        let id = UUID()
        subscriptions.append(Subscription(id: id, handler: handler))
        return id
    }

    func unsubscribe(id: UUID) {
        subscriptions.removeAll { $0.id == id }
    }

    func notify(_ event: E) -> Bool {
        for subscription in subscriptions {
            if subscription.handler(event) { return true }
        }
        return false
    }
}
```

### 2. KeyDown event + observer

```swift
struct KeyDownEvent: AppEvent {
    let keyCode: UInt16
    let characters: String?
    let modifiers: NSEvent.ModifierFlags
}
```

```swift
// Captures global keyboard events via CGEventTap and fires KeyDownEvent.
// Uses ConsumingEventObserver: first subscriber returning true consumes the event.
final class KeyDownObserver: ConsumingEventObserver<KeyDownEvent> {
    static let shared = KeyDownObserver()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard AXIsProcessTrusted() else { return }
        installEventTap()
    }

    func stop() {
        // Disable tap, remove from run loop (same as current KeybindingService.stop)
    }

    func restart() {
        stop()
        start()
    }

    private func installEventTap() {
        // Same CGEvent.tapCreate logic as current KeybindingService.installEventTap
        // In the callback: construct KeyDownEvent and call notify()
        // If notify returns true → return nil (consumed)
        // If notify returns false → return the event (pass through)
    }
}
```

Refactor `KeybindingService`:
- Remove `eventTap`, `runLoopSource`, `installEventTap()` — these move to `KeyDownObserver`
- `start()` becomes: parse bindings, then subscribe to `KeyDownObserver`
- The subscriber closure matches modifiers + key against bindings and returns true if consumed
- `stop()` calls `KeyDownObserver.shared.unsubscribe(id:)` and clears bindings
- Keep `parse()`, `displayString()`, `findDuplicate()`, `normalize()`, `buildBindings()`, `makeBuiltInCandidates()`, `makeCommandCandidates()` — these are binding management, not observation

```swift
func start() {
    guard AXIsProcessTrusted() else { return }
    let all = makeBuiltInCandidates() + makeCommandCandidates()
    guard buildBindings(from: all) else { return }

    subscriptionId = KeyDownObserver.shared.subscribe { [weak self] event in
        guard let self else { return false }
        for binding in self.bindings {
            guard event.modifiers == binding.modifiers else { continue }
            if let keyCode = binding.keyCode {
                guard event.keyCode == keyCode else { continue }
            } else if let key = binding.key {
                guard event.characters == key else { continue }
            } else { continue }
            let action = binding.action
            DispatchQueue.main.async { action() }
            return true  // consumed
        }
        return false  // not matched
    }
}
```

### 3. DisplayLinkTick event + observer

```swift
struct DisplayLinkTickEvent: AppEvent {
    let timestamp: CFAbsoluteTime
}
```

```swift
// Drives frame-accurate tiling animations via CVDisplayLink.
// Ticks run on the CVDisplayLink render thread — subscribers must handle thread safety.
final class DisplayLinkTickObserver: EventObserver<DisplayLinkTickEvent> {
    static let shared = DisplayLinkTickObserver()
    private var displayLink: CVDisplayLink?

    func startIfNeeded() {
        guard displayLink == nil else { return }
        // Same CVDisplayLinkCreate + callback as current AnimationService
        // Callback calls notify(DisplayLinkTickEvent(timestamp: CFAbsoluteTimeGetCurrent()))
    }

    func stopIfIdle() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }
}
```

`AnimationService` changes:
- Remove `displayLink`, `startDisplayLinkIfNeeded()`, `stopDisplayLinkIfIdle()`
- In `animate()`: call `DisplayLinkTickObserver.shared.startIfNeeded()` when adding animation
- Subscribe to `DisplayLinkTickObserver` once at init:
  ```swift
  DisplayLinkTickObserver.shared.subscribe { [weak self] event in
      self?.tickAll()
  }
  ```
- In `tickAll()` completion: call `DisplayLinkTickObserver.shared.stopIfIdle()`

### 4. ScrollingDisplayLinkTick — same pattern

Separate observer because scrolling animations have independent lifecycle. Same structure as `DisplayLinkTickObserver` but for `ScrollingAnimationService`.

### 5. WindowOcclusion event + observer

```swift
struct WindowOcclusionChangedEvent: AppEvent {
    let window: NSWindow
    let isVisible: Bool
}
```

```swift
// Observes NSWindow occlusion state changes and fires WindowOcclusionChangedEvent.
final class WindowOcclusionChangedObserver: EventObserver<WindowOcclusionChangedEvent> {
    static let shared = WindowOcclusionChangedObserver()
    private var observed: [ObjectIdentifier: NSObjectProtocol] = [:]

    func subscribe(window: NSWindow, handler: @escaping (WindowOcclusionChangedEvent) -> Void) -> UUID {
        let id = super.subscribe(handler: handler)
        let winID = ObjectIdentifier(window)
        if observed[winID] == nil {
            let obs = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self, weak window] _ in
                guard let window else { return }
                let visible = window.occlusionState.contains(.visible)
                self?.notify(WindowOcclusionChangedEvent(window: window, isVisible: visible))
            }
            observed[winID] = obs
        }
        return id
    }

    func stopObserving(window: NSWindow) {
        let winID = ObjectIdentifier(window)
        if let obs = observed.removeValue(forKey: winID) {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}
```

`GifImageView` changes:
- Remove `occlusionObserver` property and `observeOcclusion()` / `deinit` cleanup
- In `load()` after building animation: subscribe to `WindowOcclusionChangedObserver`
- In `stop()`: unsubscribe and call `stopObserving(window:)`

### 6. Clean up old Observation directory

After all stages, `Services/Observation/` should contain only:
- `AppObserverManager.swift` (still used by `WindowCreatedObserver` and `FocusedWindowChangedObserver` from stage 4)
- `DragReapplyScheduler.swift` (still used by `WindowTracker`)
- `SwapOverlay.swift`
- `WindowTracker.swift` (created in stage 5)

If `AppObserverManager` was absorbed into the new observers in stage 4, delete it.

### 7. Update CODE.md

Add `Events/` and `Observers/` directory sections with file descriptions.

---

## Key Technical Notes

- **CVDisplayLink thread safety**: `DisplayLinkTickObserver.notify()` runs on the CVDisplayLink render thread, NOT the main thread. Subscribers (`AnimationService.tickAll()`) must use their own locking (the existing `OSAllocatedUnfairLock` pattern). Do NOT dispatch to main thread in the observer — that would defeat the purpose of frame-accurate timing.
- **CGEventTap callback constraint**: The tap callback must be a C function pointer. `KeyDownObserver` constructs the `KeyDownEvent` inside the callback and calls `notify()`. The `notify()` call happens on the event tap thread (which is the main run loop for HID taps). The callback returns nil if `notify()` returns true.
- **KeyDownObserver start/stop lifecycle**: `KeyDownObserver.shared.start()` is called once in `UnnamedWindowManagerApp`. `KeybindingService.restart()` calls `unsubscribe` + `subscribe` to reload bindings, NOT `KeyDownObserver.stop/start` (the tap stays active).
- **Modifier stripping**: The current `KeybindingService` strips `.numericPad` and `.function` from modifier flags (line 139). This logic moves into `KeyDownObserver` when constructing the event, so subscribers see clean modifiers.
- **Two CVDisplayLink observers**: Tiling and scrolling animations use separate CVDisplayLinks because they have independent start/stop lifecycles. A single shared link would require coordination logic that doesn't exist today.
- **WindowOcclusionChangedObserver per-window subscription**: Unlike other observers, this one registers NSNotification observers per-window. The `subscribe(window:handler:)` override takes an NSWindow argument. Multiple GifImageViews can observe different windows independently.

---

## Verification

1. Build — no errors
2. Global keyboard shortcuts work (tile, untile, focus navigation, swap, scroll)
3. Shortcut conflict detection still shows notification
4. Tiling animation plays smoothly (not janky from thread dispatch)
5. Scrolling animation plays smoothly during scroll left/right
6. GIF wallpaper animates when visible, pauses when occluded
7. Static wallpaper (PNG) still displays correctly
8. `CODE.md` accurately reflects new directory structure
9. No remaining files in `Services/Observation/` that should have been migrated
10. Grep for `NotificationCenter.default.post(name:` — should find zero instances of old notification names
