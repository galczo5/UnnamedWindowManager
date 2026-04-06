# Code Structure

## Top-Level Layout

```
UnnamedWindowManager/
├── UnnamedWindowManagerApp.swift   # App entry point
├── AppDelegate.swift               # Lifecycle, observer startup, menu bar
├── Logger.swift                    # File-based debug logger
├── Config/                         # Configuration loading and accessors
├── Debug/                          # Debug-only logging utilities
├── Events/                         # AppEvent protocol and event data structs
├── Model/                          # Data types (slots, orientations, enums)
├── Observers/                      # EventObserver base class and observer subclasses
├── Services/                       # All business logic (see below)
└── build.sh                        # CLI build script (xcodebuild wrapper)
```

## Debug

Debug-only utilities for logging on-screen windows and slot trees.

| File | Description |
|------|-------------|
| `DebugLogger.swift` | Debug logging of on-screen windows and slot tree |

## Events

Marker protocol and event data structs shared across all observer classes.

| File | Description |
|------|-------------|
| `AppActivatedEvent.swift` | Event carrying the app that just became frontmost |
| `AppTerminatedEvent.swift` | Event carrying the app that just terminated |
| `DisplayLinkTickEvent.swift` | Event fired on each CVDisplayLink frame tick for tiling animations |
| `EventProtocol.swift` | Marker protocol `AppEvent` that all event data structs conform to |
| `FocusedWindowChangedEvent.swift` | Event carrying the pid of the app whose focused window changed |
| `KeyDownEvent.swift` | Event carrying key code, characters, and modifier flags for a global key-down |
| `ScreenParametersChangedEvent.swift` | Event fired when screen parameters change (resolution, display connect/disconnect) |
| `ScrollingDisplayLinkTickEvent.swift` | Event fired on each CVDisplayLink frame tick for scrolling animations |
| `SpaceChangedEvent.swift` | Event fired when the active macOS space changes |
| `TileStateChangedEvent.swift` | Event fired when the tiling/scrolling layout state changes |
| `WindowCreatedEvent.swift` | Event carrying the new window element, pid, app name, title, and window hash |
| `WindowDestroyedEvent.swift` | Event carrying the key and pid of a destroyed tracked window |
| `WindowFocusChangedEvent.swift` | Event fired when the focused window changes |
| `WindowMiniaturizedEvent.swift` | Event carrying the key and pid of a miniaturized tracked window |
| `WindowMovedEvent.swift` | Event carrying the key, element, and pid of a moved tracked window |
| `WindowOcclusionChangedEvent.swift` | Event fired when an NSWindow's occlusion state changes |
| `WindowResizedEvent.swift` | Event carrying the key, element, pid, and fullscreen flag of a resized tracked window |
| `WindowTitleChangedEvent.swift` | Event carrying the key and pid of a tracked window whose title changed |

## Observers

Pub/sub base class for all observer types in the app.

| File | Description |
|------|-------------|
| `AppActivatedObserver.swift` | Wraps `NSWorkspace.didActivateApplicationNotification` as a pub/sub event |
| `AppTerminatedObserver.swift` | Wraps `NSWorkspace.didTerminateApplicationNotification` as a pub/sub event |
| `ConsumingEventObserver.swift` | Base class for observers where the first subscriber returning true consumes the event |
| `DisplayLinkTickObserver.swift` | Drives tiling animations via CVDisplayLink; call `startIfNeeded()`/`stopIfIdle()` |
| `EventObserver.swift` | Generic base class with `subscribe`/`unsubscribe`/`notify` pub/sub mechanics |
| `FocusedWindowChangedObserver.swift` | Manages per-app AXObservers for focused-window changes; fires on app activation too |
| `KeyDownObserver.swift` | Wraps CGEventTap and fires `KeyDownEvent`; consuming — first true subscriber stops propagation |
| `ScreenParametersChangedObserver.swift` | Wraps `NSApplication.didChangeScreenParametersNotification` as a pub/sub event |
| `ScrollingDisplayLinkTickObserver.swift` | Drives scrolling animations via CVDisplayLink; call `startIfNeeded()`/`stopIfIdle()` |
| `SpaceChangedObserver.swift` | Wraps `NSWorkspace.activeSpaceDidChangeNotification`; handles displaced-window untiling and root-type tracking |
| `TileStateChangedObserver.swift` | Pure relay hub; `ReapplyHandler` and untile handlers call `notify()` directly |
| `WindowCreatedObserver.swift` | Manages per-app AXObservers for `kAXWindowCreatedNotification` and fires `WindowCreatedEvent` |
| `WindowDestroyedObserver.swift` | Notifies subscribers when a tracked window is destroyed |
| `WindowEventRouter.swift` | Owns per-PID AXObservers, routes AX callbacks to the appropriate typed observer |
| `WindowFocusChangedObserver.swift` | Pure relay hub; fired by `FocusedWindowChangedObserver` subscriber |
| `WindowMiniaturizedObserver.swift` | Notifies subscribers when a tracked window is miniaturized |
| `WindowMovedObserver.swift` | Notifies subscribers when a tracked window is moved |
| `WindowOcclusionChangedObserver.swift` | Observes per-window occlusion state changes via `NSWindow.didChangeOcclusionStateNotification` |
| `WindowResizedObserver.swift` | Notifies subscribers when a tracked window is resized (including fullscreen entry) |
| `WindowTitleChangedObserver.swift` | Notifies subscribers when a tracked window's title changes |

## Config

Reads, parses, and exposes `~/.config/unnamed/config.yml`.

| File | Description |
|------|-------------|
| `Config.swift` | Singleton with static accessors for all config values |
| `ConfigData.swift` | Codable model mapping to YAML structure, with defaults and merge logic |
| `ConfigLoader.swift` | Loads/writes `~/.config/unnamed/config.yml`, creates from defaults when absent |
| `SystemColor.swift` | Maps config color name strings to NSColor values |

## Model

Value types that represent the slot tree and layout state. No business logic.

| File | Description |
|------|-------------|
| `Slot.swift` | Top-level slot enum (`.window`, `.split`, `.stacking`) |
| `WindowSlot.swift` | Leaf node — one managed window with its AX identity and pre-tile frame |
| `SplitSlot.swift` | Binary split container (horizontal or vertical) |
| `StackingSlot.swift` | Stacked children (used in scrolling side slots) |
| `TilingRoot/TilingRootSlot.swift` | Root of a tiling tree with all tree operations (query, mutation, insert, sizing, resize) |
| `TilingRoot/TilingSlotRecursion.swift` | Static recursive helpers for Slot-level tree operations used by TilingRootSlot |
| `ScrollingRoot/ScrollingRootSlot.swift` | Root of a scrolling layout — left/center/right zones — with all query, mutation, and sizing operations |
| `ScrollingRoot/ScrollingSlotLocation.swift` | Enum identifying which zone (center, left, right) a window occupies in a scrolling root |
| `RootSlot.swift` | Enum wrapping `.tiling` or `.scrolling` root |
| `Orientation.swift` | `.horizontal` / `.vertical` |
| `StackingAlign.swift` | `.left` / `.right` alignment for stacking slots |
| `DropTarget.swift` | Drop zone hit-test result (window + zone) |

## Services

All business logic lives under `Services/`, organized by domain.

### Services/AutoMode/

Auto-tile mode that snaps newly focused windows into the active layout.

| File | Description |
|------|-------------|
| `AutoModeHandler.swift` | Routes a newly focused untracked window into the active tiling or scrolling layout |
| `AutoModeService.swift` | Observable singleton tracking auto mode enabled/disabled state |

### Services/Tiling/

Tiling slot tree management and layout application.

| File | Description |
|------|-------------|
| `TilingRootStore.swift` | Read-only queries and lookup helpers for tiling roots |
| `TilingService.swift` | All tiling store operations: snap/remove windows and structural edits (resize, swap, flip, insert) |
| `TilingNeighborService.swift` | Spatial neighbor-finding for directional operations |
| `LayoutService.swift` | Walks the tiling tree and applies window positions via AX API |

### Services/Scrolling/

Scrolling layout management (left/center/right zones with stacking sides).

| File | Description |
|------|-------------|
| `ScrollingRootStore.swift` | Thread-safe store wrapper; delegates all tree logic to ScrollingRootSlot methods |
| `ScrollingLayoutService.swift` | Applies window positions for scrolling roots via AX API |
| `ScrollingAnimationService.swift` | Direction-aware animator for scroll left/right; uses before-state positions to prevent jump artefacts |
| `ScrollingFocusService.swift` | Left/right navigation, rotating windows between zones |

### Services/Handlers/

Keyboard shortcut entry points. Each handler is invoked by `KeybindingService` and delegates to the appropriate service. Most are thin (6–11 lines).

| File | Description |
|------|-------------|
| `FocusDown/Left/Right/UpHandler.swift` | Directional focus (delegates to FocusDirectionService) |
| `SwapDown/Left/Right/UpHandler.swift` | Directional swap (delegates to SwapDirectionService) |
| `TileHandler.swift` | Tile focused window (tile, toggle, drag-tile) |
| `TileAllHandler.swift` | Batch-tile all visible windows |
| `UntileHandler.swift` | Remove windows from tiling layout |
| `ScrollHandler.swift` | Create/toggle scrolling root |
| `ScrollAllHandler.swift` | Batch-scroll all visible windows |
| `UnscrollHandler.swift` | Remove windows from scrolling layout |
| `OrientFlipHandler.swift` | Read/flip parent container orientation |
| `ReapplyHandler.swift` | Orchestrates layout reapplication with debouncing and validation |

### Services/Navigation/

Cross-layout directional services used by focus and swap handlers.

| File | Description |
|------|-------------|
| `FocusDirectionService.swift` | Activates the nearest window in a direction |
| `SwapDirectionService.swift` | Swaps focused window with its directional neighbor |

### Services/Observation/

Event-driven observers that react to AX notifications, app lifecycle, and screen changes.

| File | Description |
|------|-------------|
| `DragReapplyScheduler.swift` | Polls for mouse-up during drag and triggers reapply |
| `SwapOverlay.swift` | Translucent overlay shown over drop targets during drag |
| `WindowTracker.swift` | Central registry mapping WindowSlots to AXUIElements, PIDs, and reapply state |

### Services/Wallpaper/

Desktop wallpaper overlay (PNG, JPG, animated GIF) rendered behind all windows.

| File | Description |
|------|-------------|
| `WallpaperWindow.swift` | Borderless NSWindow pinned to desktop level, click-through, all spaces |
| `GifImageView.swift` | NSView that decodes and animates image frames via CGImageSource |
| `WallpaperService.swift` | Singleton managing one wallpaper window per connected screen |

### Services/Window/

Window utilities, AX helpers, and validation.

| File | Description |
|------|-------------|
| `AnimationService.swift` | Animates window frames via interpolated AX calls over a configurable duration |
| `AXHelpers.swift` | Low-level AX API helpers (read size/origin, window ID) |
| `BorderDrawingView.swift` | NSView that draws a border ring using Core Graphics even-odd clipping |
| `FocusChangeHandler.swift` | Handles focus change effects: tab detection, dimming, border, scroll-to-center |
| `FocusedWindowBorderService.swift` | Manages a border overlay window drawn above the focused managed window |
| `KeybindingService.swift` | Registers global keyboard shortcuts via CGEventTap |
| `OnScreenWindowCache.swift` | Time-cached CGWindowList result (50ms) |
| `PostResizeValidator.swift` | Detects and corrects windows that refused a resize |
| `RestoreService.swift` | Restores a window to its pre-tile frame via AX |
| `SettlePoller.swift` | Polls a condition every 20ms until satisfied or timeout (`animationDuration + 0.1`) elapses |
| `TabDetector.swift` | Detects native macOS tab groups by matching same-PID windows with identical CGWindow bounds |
| `WindowCornerRadius.swift` | Detects per-window corner radii via SkyLight API, pixel scan, or OS fallback |
| `WindowOpacityService.swift` | Dims non-focused windows via per-root overlays |

### Services/ (root)

Cross-cutting services that don't belong to a single domain.

| File | Description |
|------|-------------|
| `CommandService.swift` | Executes shell commands from user-configured shortcuts |
| `NotificationService.swift` | Posts user-facing system notifications |
| `Screen.swift` | Screen geometry utilities: usable tiling area and AX layout origin |
| `SharedRootStore.swift` | Thread-safe store for all layout roots (tiling + scrolling) |
