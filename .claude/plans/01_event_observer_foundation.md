# Plan: 01_event_observer_foundation — Base event/observer infrastructure

## Checklist

- [x] Create `Events/` directory and `EventProtocol.swift`
- [x] Create `Observers/` directory and `EventObserver.swift` base class
- [x] Add both directories to the Xcode project
- [x] Verify the app builds and runs with no behavioral changes

---

## Context / Problem

The app currently has 6+ observer classes using heterogeneous mechanisms (AXObserver, NSWorkspace, CGEventTap, CVDisplayLink, NSWindow notifications). There is no unified event model — observers directly call handler methods when events fire.

This stage introduces the foundation: an `Events/` directory for event data structs and an `Observers/` directory for observer classes that use a shared pub/sub base class. No existing code is modified — this is purely additive.

---

## Pub/sub design

The base class `EventObserver<E>` provides:
- A `subscriptions` array of `(id: UUID, handler: (E) -> Void)` tuples
- `subscribe(handler:) -> UUID` for global observers (no per-element args)
- `unsubscribe(id:)` removes by UUID
- `notify(_:)` iterates all subscriptions and calls handlers

Per-window observers (stages 4–5) will **not** use the base `subscribe` — they define their own typed `subscribe(windowHash:handler:)` that filters events by window identity before notifying. They still use the base `notify` and `unsubscribe` machinery.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Events/EventProtocol.swift` | **New file** — empty protocol marker for all event structs |
| `UnnamedWindowManager/Observers/EventObserver.swift` | **New file** — generic base class with pub/sub mechanics |

---

## Implementation Steps

### 1. Create `Events/EventProtocol.swift`

```swift
// Marker protocol for all event data types in the app.
protocol AppEvent {}
```

All event structs in later stages will conform to `AppEvent`. This keeps the event directory self-documenting and enables future generic constraints.

### 2. Create `Observers/EventObserver.swift`

```swift
// Generic base class providing pub/sub mechanics for all observers.
// Subclasses override `start()` to wire up their platform-specific observation
// mechanism and call `notify(_:)` when an event occurs.
class EventObserver<E: AppEvent> {
    struct Subscription {
        let id: UUID
        let handler: (E) -> Void
    }

    private(set) var subscriptions: [Subscription] = []

    @discardableResult
    func subscribe(handler: @escaping (E) -> Void) -> UUID {
        let id = UUID()
        subscriptions.append(Subscription(id: id, handler: handler))
        return id
    }

    func unsubscribe(id: UUID) {
        subscriptions.removeAll { $0.id == id }
    }

    func notify(_ event: E) {
        for subscription in subscriptions {
            subscription.handler(event)
        }
    }
}
```

### 3. Add to Xcode project

Create the `Events/` and `Observers/` groups in the project navigator and add both files to the `UnnamedWindowManager` target.

---

## Key Technical Notes

- `EventObserver` is a class (not struct) because observers are long-lived singletons with mutable subscription state.
- `subscriptions` is `private(set)` so subclasses can read but not directly mutate — they go through `subscribe`/`unsubscribe`.
- `notify` runs synchronously on the caller's thread. AX callbacks arrive on the main thread (via CFRunLoop), NSWorkspace notifications on main, CVDisplayLink on its render thread. Each observer subclass is responsible for dispatching to the correct thread before calling `notify`.
- The `@discardableResult` on `subscribe` allows callers that never unsubscribe (e.g. app-lifetime subscriptions) to ignore the UUID.

---

## Verification

1. Build the project — no errors
2. Run the app — all existing functionality works unchanged
3. Confirm `Events/` and `Observers/` directories exist with their files
