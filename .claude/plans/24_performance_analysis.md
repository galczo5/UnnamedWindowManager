# Plan: 24_performance_analysis — Performance Improvement Analysis

## Checklist

- [x] Audit Accessibility API call density in layout and drag paths
- [x] Audit CGWindowListCopyWindowInfo redundancy across subsystems
- [x] Audit linear searches in hot-path callbacks (ResizeObserver, FocusObserver)
- [x] Audit full-tree-rebuild pattern in LayoutService
- [x] Audit 10ms polling loop and drop-target search during drag
- [x] Audit AXObserver consolidation opportunities
- [x] Audit overlay and animation overhead (SwapOverlay, WindowOpacityService)
- [x] Audit SharedRootStore synchronization overhead
- [x] Produce improvement plan (plan 25)

---

## Context / Problem

The app is a macOS tiling window manager that relies heavily on the Accessibility API (AX) for reading and writing window geometry, and on `CGWindowListCopyWindowInfo` for enumerating on-screen windows. These system calls are expensive — AX calls are synchronous IPC to the target app's process, and `CGWindowListCopyWindowInfo` queries the window server for every window on the system.

The app is already responsive for small window counts, but as more windows are tiled (or during rapid drag operations), CPU usage can spike due to:
- Redundant AX reads during drag (drop-target detection + overlay update + reapply)
- Full tree walks on every layout change with no incremental updates
- Multiple `CGWindowListCopyWindowInfo` calls per operation
- Linear searches through tracked elements on every AX notification

**Goal:** Systematically audit each performance-critical path, quantify the cost, and produce a concrete improvement plan (plan 25) with prioritized changes.

---

## Audit Areas

### Area 1: Accessibility API Call Density

**Current state:** Every `LayoutService.applyLayout` call walks the entire slot tree and issues 2 AX write calls (`kAXPositionAttribute` + `kAXSizeAttribute`) per window — even windows whose position and size haven't changed.

**Files:** `LayoutService.swift:49-81`, `ScrollingLayoutService.swift:35-57`

**What to measure:**
- How many AX calls occur per reapplyAll cycle
- Whether skip-unchanged optimization is feasible (compare target pos/size to last-applied values)

**During drag:** `ReapplyHandler.findDropTarget` (line 53-88) issues 2 AX *read* calls per leaf window (`readOrigin` + `readSize`) to find which window the cursor is over. This runs on every mouse-move notification — potentially hundreds of times per drag.

**Files:** `ReapplyHandler.swift:53-88`

**Additionally:** `SwapOverlay.update` (line 7-21) does 2 more AX reads for the target window to position the overlay. `PostResizeValidator.checkAndFixRefusals` does 1 AX read per window.

### Area 2: CGWindowListCopyWindowInfo Redundancy

**Current state:** Multiple subsystems independently call `CGWindowListCopyWindowInfo`:

| Caller | Filter | Purpose |
|--------|--------|---------|
| `ReapplyHandler.onScreenWindowIDs()` | `.optionOnScreenOnly` | Prune off-screen windows |
| `AutoTileObserver.allWindowIDs()` | `.excludeDesktopElements` (ALL) | Prune stale slots for a PID |
| `AutoTileObserver.windowsOnScreen()` | `.optionOnScreenOnly` | Check if screen was empty |
| `OrganizeHandler.organize()` | `.optionOnScreenOnly` | Enumerate candidates |
| `WindowLister.logAllWindows()` | `.optionOnScreenOnly` | Debug logging |

**What to examine:**
- Can a shared, time-limited cache (e.g., valid for 100ms) serve multiple callers within the same operation?
- `AutoTileObserver.allWindowIDs` uses NO on-screen filter, querying ALL system windows just to check one PID's windows

### Area 3: Linear Searches in Hot-Path Callbacks

**ResizeObserver.handle()** (line 59-61): On every AX move/resize notification, finds the matching `WindowSlot` by iterating all keys for that PID and calling `CFEqual` on each. `CFEqual` on `AXUIElement` is an IPC call to the target app.

```swift
guard let key = keysByPid[pid]?.first(where: {
    elements[$0].map { CFEqual($0, element) } == true
}) else { return }
```

**FocusObserver.executeDim()** (line 70): On every focus change, iterates ALL elements (not just the current PID's) to find the focused window:

```swift
guard let (key, _) = elements.first(where: { CFEqual($0.value, axWindow) }) else { ... }
```

**What to examine:**
- Can we maintain a reverse lookup (`AXUIElement` → `WindowSlot`) using CGWindowID as key?
- CGWindowID is available via `_AXUIElementGetWindow()` (already used in `windowID(of:)` helper) and would allow O(1) lookup

### Area 4: Full Tree Rebuild Pattern

**Current state:** `LayoutService.applyLayout` always walks the complete tree and writes position+size to every window. There's no dirty-flag or change-tracking mechanism.

**Files:** `LayoutService.swift:11-25`, `LayoutService.swift:29-81`

**What to examine:**
- Can we cache last-applied `(position, size)` per `WindowSlot` and skip AX calls when unchanged?
- The slot tree already stores `width`/`height` — we could compare against a "last applied" snapshot
- Trade-off: adds state tracking complexity, but AX writes are expensive IPC

### Area 5: Drag Polling Loop

**Current state:** `ResizeObserver.scheduleReapplyWhenMouseUp` polls every 10ms. During drag, each poll:
1. Checks `NSEvent.pressedMouseButtons` — cheap
2. If mouse still held, reschedules — recursion via `DispatchQueue.main.asyncAfter`

But the AX notification callback (`handle()`) fires on every mouse-move during drag, and:
1. Calls `findDropTarget` → 2 AX reads × N leaves
2. Updates `SwapOverlay` → 2 more AX reads for target window

**Files:** `ResizeObserver.swift:86-93`, `ResizeObserver.swift:134-198`

**What to examine:**
- Can drop-target detection use cached/stored positions from the slot tree instead of live AX reads?
- The slot tree already knows each window's target position and size
- Only the *dragged* window changes position — all other windows should be at their target positions
- This would eliminate 2×N AX reads per drag notification

### Area 6: AXObserver Consolidation

**Current state:** Three separate classes create AXObservers:

| Class | Scope | Notifications |
|-------|-------|---------------|
| `ResizeObserver` | Per-PID, per-window | move, resize, destroy |
| `AutoTileObserver` | Per-app | windowCreated |
| `FocusObserver` | Per-app | focusedWindowChanged |

Each calls `AXObserverCreate` and `CFRunLoopAddSource` independently. For a single app, this means up to 3 separate AXObservers registered on the main run loop.

**What to examine:**
- Can `AutoTileObserver` and `FocusObserver` share a single per-app AXObserver?
- Both register at the app level (not per-window). A combined observer would halve the per-app overhead
- Trade-off: coupling between observer subsystems vs. reduced system resource usage

### Area 7: Overlay and Animation Overhead

**WindowOpacityService:** Creates a full-screen NSWindow overlay per root. On every focus change:
- Updates overlay frame to screen size
- Calls `win.order(.below, relativeTo:)` — requires window server IPC
- Runs `NSAnimationContext` animation

**SwapOverlay:** During drag, on every mouse-move:
- Reads 2 AX attributes for the target
- Calls `win.setFrame` + `win.order` — two window server IPCs

**Files:** `WindowOpacityService.swift:15-45`, `SwapOverlay.swift:7-47`

**What to examine:**
- Is `setFrame(display: false)` sufficient or is the `order()` call the real cost?
- Can overlay updates be throttled during drag (e.g., only update if target changed)?
- SwapOverlay already has target-change detection in `ResizeObserver.updateTrackedDropTarget` — but the overlay `update()` still fires on every move

### Area 8: SharedRootStore Synchronization

**Current state:** `SharedRootStore` uses a concurrent `DispatchQueue` with `.sync` for reads and `.sync(flags: .barrier)` for writes. Every `isTracked()`, `leavesInVisibleRoot()`, `snapshotVisibleRoot()` call goes through this queue.

**Files:** `SharedRootStore.swift`, `TileService.swift`

**What to examine:**
- Since all AX callbacks and UI updates are dispatched to `DispatchQueue.main`, is the concurrent queue providing value or just adding overhead?
- If all access is effectively single-threaded (main queue), a simple property with main-thread assertions would be cheaper
- Count how many queue.sync calls occur per operation (e.g., during reapplyAll)

---

## Implementation Steps

### 1. Instrument AX call counts

Add temporary counters to `LayoutService.applyLayout` (the recursive `applyLayout(_:origin:elements:)` method) and `readOrigin`/`readSize` helpers. Log total AX reads and writes per operation. Use this data to validate which optimizations would have the highest impact.

### 2. Profile drag operations

With 4-6 windows tiled, perform a slow drag across the screen. Count:
- Total AX notifications received
- Total `findDropTarget` calls
- Total AX reads during the drag
- Total overlay updates

### 3. Measure CGWindowList call frequency

Log timestamps in each `CGWindowListCopyWindowInfo` call site. Identify cases where multiple calls happen within the same operation (< 100ms apart).

### 4. Evaluate each optimization

For each area, assess:
- **Impact:** How many AX/system calls does it eliminate?
- **Complexity:** How much code changes?
- **Risk:** Could it introduce visual glitches or state inconsistency?

### 5. Produce plan 25

Write a concrete implementation plan with prioritized improvements, ordered by impact/complexity ratio.

---

## Key Technical Notes

- AX calls (`AXUIElementSetAttributeValue`, `AXUIElementCopyAttributeValue`) are synchronous IPC — they block the calling thread until the target app responds. A hung target app can stall the entire window manager.
- `CFEqual` on `AXUIElement` is also IPC — it queries the target process to compare element identities.
- `CGWindowListCopyWindowInfo` queries the window server and returns all matching windows system-wide. With many apps open, this list can be large.
- The slot tree stores target positions/sizes, but `findDropTarget` reads *actual* positions from AX because the dragged window's actual position differs from its target. However, all *non-dragged* windows should match their targets.
- `NSEvent.pressedMouseButtons` is a cheap local query (no IPC).
- The 10ms debounce on `reapplyAll` already collapses multiple rapid calls effectively. The issue is the work done *within* a single reapply cycle.

---

## Verification

1. Read each file listed in the audit areas and confirm the described patterns exist
2. Validate AX call counts by temporarily instrumenting the code
3. Confirm that the produced plan 25 addresses findings proportional to their impact
