# Code Structure

## Top-Level Layout

```
UnnamedWindowManager/
├── UnnamedWindowManagerApp.swift   # App entry point
├── AppDelegate.swift               # Lifecycle, observer startup, menu bar
├── Logger.swift                    # File-based debug logger
├── Bridge/                         # C bridging header and SkyLight private API stubs
├── Config/                         # Configuration loading and accessors
├── Events/                         # AppEvent protocol and event data structs
├── Model/                          # Data types (slots, orientations, enums)
├── Observers/                      # EventObserver base class and observer subclasses
├── Services/                       # All business logic (see below)
└── build.sh                        # CLI build script (xcodebuild wrapper)
```

## Events

Marker protocol and event data structs shared across all observer classes.

| File | Description |
|------|-------------|
| `EventProtocol.swift` | Marker protocol `AppEvent` that all event data structs conform to |

## Observers

Pub/sub base class for all observer types in the app.

| File | Description |
|------|-------------|
| `EventObserver.swift` | Generic base class with `subscribe`/`unsubscribe`/`notify` pub/sub mechanics |

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
| `TilingRootSlot.swift` | Root of a tiling tree — one per screen/space |
| `ScrollingRootSlot.swift` | Root of a scrolling layout — left/center/right zones |
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
| `TilingRootStore.swift` | Read-only queries and lookups for tiling roots |
| `TilingEditService.swift` | High-level structural modifications (resize, swap, flip, insert) |
| `TilingSnapService.swift` | Adds/removes windows from tiling roots |
| `TilingNeighborService.swift` | Spatial neighbor-finding for directional operations |
| `TilingPositionService.swift` | Computes pixel sizes from fractional slot shares |
| `TilingResizeService.swift` | Translates user resizes into fraction adjustments |
| `TilingTreeQueryService.swift` | Read-only tree traversal (find leaf, all leaves, max order) |
| `TilingTreeMutationService.swift` | Structural tree mutations (remove, extract, wrap, flip) |
| `TilingTreeInsertService.swift` | Insertion and swap on the slot tree |
| `LayoutService.swift` | Walks the tiling tree and applies window positions via AX API |

### Services/Scrolling/

Scrolling layout management (left/center/right zones with stacking sides).

| File | Description |
|------|-------------|
| `ScrollingRootStore.swift` | Creates/mutates ScrollingRootSlot in SharedRootStore |
| `ScrollingPositionService.swift` | Computes pixel dimensions for all scrolling zones |
| `ScrollingResizeService.swift` | Handles user-initiated resizes of the center slot |
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
| `AppObserverManager.swift` | Per-app AXObserver lifecycle (create, run-loop, cleanup) |
| `AXCallback.swift` | C-compatible callback that dispatches to ResizeObserver |
| `DragReapplyScheduler.swift` | Polls for mouse-up during drag and triggers reapply |
| `FocusObserver.swift` | Watches app/window focus changes to drive dimming |
| `ResizeObserver.swift` | Tracks AX move/resize/destroy for all managed windows |
| `ScreenChangeObserver.swift` | Reflows layout on screen resolution/display changes |
| `SpaceChangeObserver.swift` | Observes space switches, reflows layout, and untiles windows displaced by Mission Control |
| `SwapOverlay.swift` | Translucent overlay shown over drop targets during drag |
| `WindowCreationObserver.swift` | Observes kAXWindowCreatedNotification per app and routes new windows via AutoModeHandler |

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
| `FocusedWindowBorderService.swift` | Manages a border overlay window drawn above the focused managed window |
| `KeybindingService.swift` | Registers global keyboard shortcuts via CGEventTap |
| `OnScreenWindowCache.swift` | Time-cached CGWindowList result (50ms) |
| `PostResizeValidator.swift` | Detects and corrects windows that refused a resize |
| `RestoreService.swift` | Restores a window to its pre-tile frame via AX |
| `SettlePoller.swift` | Polls a condition every 20ms until satisfied or timeout (`animationDuration + 0.1`) elapses |
| `TabDetector.swift` | Detects native macOS tab groups by matching same-PID windows with identical CGWindow bounds |
| `WindowCornerRadius.swift` | Detects per-window corner radii via SkyLight API, pixel scan, or OS fallback |
| `WindowLister.swift` | Debug logging of on-screen windows and slot tree |
| `WindowOpacityService.swift` | Dims non-focused windows via per-root overlays |
| `WindowVisibilityManager.swift` | Manages auto-minimization state for tiled windows |

### Services/ (root)

Cross-cutting services that don't belong to a single domain.

| File | Description |
|------|-------------|
| `CommandService.swift` | Executes shell commands from user-configured shortcuts |
| `NotificationService.swift` | Posts user-facing system notifications |
| `ReapplyHandler.swift` | Orchestrates layout reapplication with debouncing and validation |
| `ScreenHelper.swift` | Computes usable tiling area after outer gaps |
| `SharedRootStore.swift` | Thread-safe store for all layout roots (tiling + scrolling) |
