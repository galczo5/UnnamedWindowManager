# Delays and Waiting Patterns

All delays in the app are non-blocking, using `DispatchQueue.main.asyncAfter` or recursive dispatch. There are no `Thread.sleep` or blocking waits.

## Polling Loops

### SettlePoller

Generic condition poller. Checks a condition every **20 ms** until it returns `true` or a timeout elapses (default: `Config.animationDuration + 0.1`).

Used by:
- **ReapplyHandler** — waits for window size to settle after a resize/snap so PostResizeValidator can detect refusals.
- **AutoModeHandler** — waits for window bounds to settle after auto-snap before recording the final frame.
- **FocusObserver** — waits for tab-window bounds to stabilise before deciding whether the window moved.

### AutoModeHandler – Window ID Poll

When a new app activates, the focused-window AX attribute or its `CGWindowID` may not be readable yet. A recursive poll retries every **100 ms**, up to **10 attempts** (~1 s max), until both values are stable.

File: `Services/AutoMode/AutoModeHandler.swift`

## Debouncing

### ReapplyHandler – Layout Debounce

Multiple layout-change events arriving within **10 ms** are collapsed into a single `reapplyAll()` call using a `DispatchWorkItem` that is cancelled and re-scheduled on each trigger.

File: `Services/ReapplyHandler.swift`

### DragReapplyScheduler – Drag Debounce

While a window is being dragged or resized, reapply is debounced to **10 ms**. The scheduler polls until the mouse button is released.

File: `Services/Observation/DragReapplyScheduler.swift`

## Post-Animation Delays

These wait for window animations to finish before performing follow-up work. All are expressed as `max(constant, Config.animationDuration + offset)`.

| Delay | Purpose | Location |
|-------|---------|----------|
| `max(0.2, animDur + 0.05)` | Remove windows from the "reapplying" set so ResizeObserver stops ignoring their frames | ReapplyHandler, DragReapplyScheduler |
| `max(0.3, animDur + 0.1)` | Run PostResizeValidator to detect and fix windows that refused the target size | ReapplyHandler, DragReapplyScheduler |
| `0.05` | Remove side windows from "reapplying" after a scroll animation starts so ResizeObserver resumes tracking | ScrollingAnimationService |

## Animated-Once Cache TTL

Both `AnimationService` and `ScrollingAnimationService` track which windows have already been animated so repeat layouts can skip animation. The cache entry is cleared after `Config.animatedOnceTTL`.

Files: `Services/Window/AnimationService.swift`, `Services/Scrolling/ScrollingAnimationService.swift`

## Batch Staggering

### ScrollAllHandler – Organize Scrolling

When snapping multiple windows at once, each window is delayed by **`i × 100 ms`** to avoid overwhelming the Accessibility API. A final notification fires **0.5 s** after the last window is processed.

File: `Services/Handlers/ScrollAllHandler.swift`

## Mission Control Delay

After a window is dragged to another Space via Mission Control, the system commits the move after a ~0.5–1 s animation with no AX notification. A **1.5 s** delayed reapply lets `pruneOffScreenWindows` detect the window on its new Space and untile it.

File: `Services/Observation/DragReapplyScheduler.swift`

## Next-Runloop-Cycle Dispatches

These use `DispatchQueue.main.async` (no explicit delay) to defer work by one runloop tick:

| Purpose | Location |
|---------|----------|
| Handle window-created notification | WindowCreationObserver |
| Post layout-change notification | ReapplyHandler |
| Handle focus-change notification | FocusObserver |
| Defer fade-out so a rapid restoreAll()+dim() pair can cancel | WindowOpacityService |
