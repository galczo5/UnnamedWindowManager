# Observers

All observer types live in `UnnamedWindowManager/Observers/`.

## Base Classes

### EventObserver

Generic base class providing pub/sub mechanics (`subscribe`/`notify`) for all observers. Every concrete observer below extends this class.

### ConsumingEventObserver

Subclass of `EventObserver` where subscribers can consume events (return `true` to stop propagation). Used by `KeyDownObserver`.

## Concrete Observers

### AppActivatedObserver

Wraps `NSWorkspace.didActivateApplicationNotification`.

| Subscription site | Purpose |
|---|---|
| `UnnamedWindowManagerApp.swift` | `.start()` — begin observing |
| `WindowCreatedObserver.swift` | Observe new windows in activated apps |
| `FocusedWindowChangedObserver.swift` | Observe focus changes in activated apps |

### AppTerminatedObserver

Wraps `NSWorkspace.didTerminateApplicationNotification`.

| Subscription site | Purpose |
|---|---|
| `UnnamedWindowManagerApp.swift` | `.start()` — begin observing |
| `WindowCreatedObserver.swift` | Cleanup observers for terminated apps |
| `FocusedWindowChangedObserver.swift` | Cleanup observers for terminated apps |

### DisplayLinkTickObserver

Drives frame-accurate tiling animations via CVDisplayLink.

| Subscription site | Purpose |
|---|---|
| `TilingAnimationService.swift` | Subscribed to animate window frames on each tick; calls `.startIfNeeded()` / `.stopIfIdle()` to manage the display link lifecycle |

### FocusedWindowChangedObserver

Manages per-app AXObservers for focused-window changes; also fires on app activation.

| Subscription site | Purpose |
|---|---|
| `UnnamedWindowManagerApp.swift` | `.start()` — begin observing; subscribed to notify `WindowFocusChangedObserver` and handle focus changes |

### KeyDownObserver

Captures global keyboard events via `CGEventTap`. Extends `ConsumingEventObserver` — first subscriber returning `true` stops propagation.

| Subscription site | Purpose |
|---|---|
| `UnnamedWindowManagerApp.swift` | `.start()` — install event tap |
| `KeybindingService.swift` | Subscribed to match and handle keyboard shortcuts |

### ScreenParametersChangedObserver

Wraps `NSApplication.didChangeScreenParametersNotification`.

| Subscription site | Purpose |
|---|---|
| `UnnamedWindowManagerApp.swift` | `.start()` — begin observing; subscribed to recompute layout when screen parameters change |

### ScrollingDisplayLinkTickObserver

Drives frame-accurate scrolling animations via CVDisplayLink.

| Subscription site | Purpose |
|---|---|
| `ScrollingAnimationService.swift` | Subscribed to animate scrolling window frames on each tick; calls `.startIfNeeded()` / `.stopIfIdle()` to manage the display link lifecycle |

### SpaceChangedObserver

Wraps `NSWorkspace.activeSpaceDidChangeNotification`. Handles displaced-window untiling and root-type tracking internally.

| Subscription site | Purpose |
|---|---|
| `UnnamedWindowManagerApp.swift` | `.start()` — begin observing; subscribed to update menu state when space changes |

### TileStateChangedObserver

Pure relay hub; notified directly by handlers when tile state changes.

| Subscription site | Purpose |
|---|---|
| `ReapplyHandler.swift` | Notified after layout reapplication |
| `UnscrollHandler.swift` | Notified when unscrolling / unscrolling all |
| `UntileHandler.swift` | Notified when untiling all |
| `UnnamedWindowManagerApp.swift` | Subscribed to update menu state |

### WindowCreatedObserver

Manages per-app AXObservers for `kAXWindowCreatedNotification`.

| Subscription site | Purpose |
|---|---|
| `UnnamedWindowManagerApp.swift` | `.start()` — begin observing; subscribed to log window creation and handle auto mode |

### WindowDestroyedObserver

Notifies subscribers when a tracked window is destroyed.

| Subscription site | Purpose |
|---|---|
| `WindowEventRouter.swift` | Notified when AX element destroyed notification received |
| `UnnamedWindowManagerApp.swift` | Subscribed to remove window from layout |

### WindowEventRouter

Creates per-PID AXObservers, registers per-window AX notifications, routes callbacks to typed observers (`WindowDestroyedObserver`, `WindowMiniaturizedObserver`, `WindowResizedObserver`, `WindowMovedObserver`, `WindowTitleChangedObserver`).

| Subscription site | Purpose |
|---|---|
| `UnnamedWindowManagerApp.swift` | Instance stored; `.removeWindow()` called on destroy/miniaturize |
| `TileHandler.swift` | `.observe()` to track new tiled windows; `.swapTab()` for tab switching |
| `ScrollHandler.swift` | `.observe()` to track new scrolled windows |
| `TileAllHandler.swift` | `.observe()` to track new tiled windows |
| `ScrollAllHandler.swift` | `.observe()` to track new scrolled windows |
| `UnscrollHandler.swift` | `.stopObserving()` to stop tracking scrolled windows |
| `UntileHandler.swift` | `.stopObserving()` to stop tracking tiled windows |
| `FocusChangeHandler.swift` | `.swapTab()` for tab switching |
| `ReapplyHandler.swift` | `.swapTab()` for tab switching |

### WindowFocusChangedObserver

Pure relay hub; fired by `FocusedWindowChangedObserver` subscriber.

| Subscription site | Purpose |
|---|---|
| `UnnamedWindowManagerApp.swift` | Notified by `FocusedWindowChangedObserver` subscriber; subscribed to update menu state |

### WindowMiniaturizedObserver

Notifies subscribers when a tracked window is miniaturized.

| Subscription site | Purpose |
|---|---|
| `WindowEventRouter.swift` | Notified when AX window miniaturized notification received |
| `UnnamedWindowManagerApp.swift` | Subscribed to remove miniaturized window from layout |

### WindowMovedObserver

Notifies subscribers when a tracked window is moved.

| Subscription site | Purpose |
|---|---|
| `WindowEventRouter.swift` | Notified when AX window moved notification received |
| `UnnamedWindowManagerApp.swift` | Subscribed to update tracking and reflow layout |

### WindowOcclusionChangedObserver

Observes per-window occlusion state changes.

| Subscription site | Purpose |
|---|---|
| `GifImageView.swift` | Subscribed to pause/resume GIF animation based on window occlusion; unsubscribed and `.stopObserving()` called in deinit and `stop()` |

### WindowResizedObserver

Notifies subscribers when a tracked window is resized.

| Subscription site | Purpose |
|---|---|
| `WindowEventRouter.swift` | Notified when AX window resized notification received |
| `UnnamedWindowManagerApp.swift` | Subscribed to handle resize and potentially remove window (fullscreen) |

### WindowTitleChangedObserver

Notifies subscribers when a tracked window's title changes.

| Subscription site | Purpose |
|---|---|
| `WindowEventRouter.swift` | Notified when AX title changed notification received |
