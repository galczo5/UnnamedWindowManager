# Plan: 25_performance_improvements — Performance Improvements

## Checklist

- [x] Add cached `visibleRootID` / `visibleScrollingRootID` to eliminate redundant CGWindowList calls
- [x] Use slot-tree positions for drop-target detection instead of live AX reads
- [x] Skip unchanged AX writes in LayoutService
- [x] Add CGWindowID-based reverse index for O(1) element lookup
- [x] Scope FocusObserver element search to PID
- [x] Throttle SwapOverlay updates when drop target is unchanged

---

## Context / Problem

Performance analysis (plan 24) identified the following hot-path costs for a typical 6-window layout:

**Single `reapplyAll()` cycle:**
- 5 × `CGWindowListCopyWindowInfo` (heavy window-server IPC)
- 12 × `AXUIElementSetAttributeValue` (2 per window, IPC to each app)
- ~8 × `queue.sync` (dispatch queue overhead)

**Single drag-move AX notification:**
- 1 × `CGWindowListCopyWindowInfo` (for `leavesInVisibleRoot` → `visibleRootID`)
- 14 × `AXUIElementCopyAttributeValue` (2×6 leaves in `findDropTarget` + 2 for overlay)
- O(n) `CFEqual` scan to identify the moved window

**On mouse-up after drag:**
- Full `reapplyAll` (5 CGWindowList + 12 AX writes)
- `PostResizeValidator` at +300ms (6 AX reads + potentially another full cycle)

The biggest bottleneck is `CGWindowListCopyWindowInfo`: a single `reapplyAll` calls it **5 times** because `visibleRootID()` and `visibleScrollingRootID()` each query the window server independently, and they're called from both the leaf-gathering and layout-application stages.

---

## Improvement 1: Cache `visibleRootID` (High Impact, Low Complexity)

### Problem

`visibleRootID()` in `TileService` (line 286) and `visibleScrollingRootID()` in `ScrollingTileService` (line 261) each call `CGWindowListCopyWindowInfo`. During a single `reapplyAll`:

| Caller | Calls `visibleRootID` | Calls `visibleScrollingRootID` |
|--------|----------------------|-------------------------------|
| `pruneOffScreenWindows` → `onScreenWindowIDs` | — (separate call) | — |
| `leavesInVisibleRoot()` | 1 | — |
| `leavesInVisibleScrollingRoot()` | — | 1 |
| `LayoutService.applyLayout` → `snapshotVisibleRoot` | 1 | — |
| `LayoutService.applyLayout` → `snapshotVisibleScrollingRoot` | — | 1 |

That's 4 redundant calls (the first `onScreenWindowIDs` is a 5th). All 5 calls happen within < 1ms of each other in the same `reapplyAll` dispatch.

### Solution

Add a time-based cache to `visibleRootID()` and `visibleScrollingRootID()`. If the cached result is < 50ms old, return it without querying the window server. Additionally, share the `onScreenWindowIDs` set between `pruneOffScreenWindows` and the `visibleRootID` calls.

### Implementation

Store a `(result: UUID?, timestamp: DispatchTime)` tuple. At the start of `visibleRootID()`, check if `DispatchTime.now() - timestamp < 50ms` and return cached result if so. Same for `visibleScrollingRootID()`.

Better yet, both methods compute the same `visibleHashes` set from the same `CGWindowListCopyWindowInfo` call. Extract a shared `OnScreenWindowCache` that caches the `Set<UInt>` for 50ms:

```swift
enum OnScreenWindowCache {
    private static var cachedHashes: Set<UInt> = []
    private static var cacheTime: UInt64 = 0

    static func visibleHashes() -> Set<UInt> {
        let now = DispatchTime.now().uptimeNanoseconds
        if now - cacheTime < 50_000_000, !cachedHashes.isEmpty {
            return cachedHashes
        }
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var ids = Set<UInt>()
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid   = info[kCGWindowOwnerPID as String] as? Int,
                  let wid   = info[kCGWindowNumber as String] as? CGWindowID,
                  pid_t(pid) != ownPID
            else { continue }
            ids.insert(UInt(wid))
        }
        cachedHashes = ids
        cacheTime = now
        return ids
    }
}
```

Then `visibleRootID()`, `visibleScrollingRootID()`, and `onScreenWindowIDs()` all call `OnScreenWindowCache.visibleHashes()`.

**Expected savings:** 4 of 5 `CGWindowListCopyWindowInfo` calls eliminated per `reapplyAll`. During drag, `leavesInVisibleRoot()` in `findDropTarget` also benefits — cached result reused across rapid notifications.

---

## Improvement 2: Use Slot-Tree Positions for Drop-Target Detection (High Impact, Medium Complexity)

### Problem

`ReapplyHandler.findDropTarget()` (line 53-88) reads live AX position and size for every leaf window to determine which window the cursor is over. With N=6 windows, that's 12 AX IPC reads per drag notification. During a drag, notifications fire on every mouse move — potentially hundreds of times.

But only the *dragged* window has moved. All other windows are at their stored slot-tree positions (set by the last `applyLayout` call). Reading their positions from AX is redundant.

### Solution

Compute target window frames from the slot tree (same math as `LayoutService.applyLayout`) instead of reading from AX. The slot tree already stores each window's `width` and `height`, and the tree walk computes each window's origin.

### Implementation

Add a method to `LayoutService` that returns precomputed frames:

```swift
func computeFrames(screen: NSScreen) -> [WindowSlot: CGRect] {
    let visible = screen.visibleFrame
    let primaryHeight = NSScreen.screens[0].frame.height
    let og = Config.outerGaps
    let origin = CGPoint(x: visible.minX + og.left!, y: primaryHeight - visible.maxY + og.top!)
    var frames: [WindowSlot: CGRect] = [:]
    if let root = TileService.shared.snapshotVisibleRoot() {
        collectFrames(root, origin: origin, into: &frames)
    }
    return frames
}
```

Then `findDropTarget` uses these precomputed frames — 0 AX calls instead of 2×N. Convert from AX coordinates (top-left origin) to AppKit coordinates (bottom-left origin) for cursor comparison, same as the current code already does.

**Expected savings:** 12+ AX reads eliminated per drag notification. For a 2-second drag with ~100 notifications, that's ~1200 AX calls saved.

---

## Improvement 3: Skip Unchanged AX Writes in LayoutService (Medium Impact, Low Complexity)

### Problem

`LayoutService.applyLayout` writes position and size to every window in the tree on every call, even when most windows haven't changed. After a single-window resize, only that window and its siblings need updating — but all N windows get 2 AX writes each.

### Solution

Cache the last-applied `(CGPoint, CGSize)` per `WindowSlot`. Before writing, compare the target values against the cache. Skip the AX calls if both position and size match (within 1pt tolerance for rounding).

### Implementation

Add a dictionary to `LayoutService`:

```swift
private var lastApplied: [WindowSlot: (pos: CGPoint, size: CGSize)] = [:]
```

In the leaf case of `applyLayout(_:origin:elements:)`:

```swift
case .window(let w):
    guard let ax = elements[w] else { return }
    let g = w.gaps ? Config.innerGap : 0
    let pos  = CGPoint(x: (origin.x + g).rounded(), y: (origin.y + g).rounded())
    let size = CGSize(width: (w.width - g * 2).rounded(), height: (w.height - g * 2).rounded())
    if let last = lastApplied[w],
       abs(last.pos.x - pos.x) < 1, abs(last.pos.y - pos.y) < 1,
       abs(last.size.width - size.width) < 1, abs(last.size.height - size.height) < 1 {
        return  // skip — window already at target
    }
    // ... existing AX write code ...
    lastApplied[w] = (pos, size)
```

Clear the cache entry when a window is removed.

**Expected savings:** After a single-window resize with N=6, typically 4-5 of 6 windows are unchanged → 8-10 AX writes eliminated. During drag reapply, all windows except the dragged one are unchanged.

---

## Improvement 4: CGWindowID Reverse Index for O(1) Lookup (Low-Medium Impact, Low Complexity)

### Problem

`ResizeObserver.handle()` (line 59-61) finds the `WindowSlot` for an AX notification by iterating all keys for the PID and calling `CFEqual` on each. `FocusObserver.executeDim()` (line 70) iterates ALL elements across all PIDs.

While `CFEqual` on `AXUIElement` is a local comparison (not IPC), the linear scan grows with window count and runs on every AX notification.

### Solution

Maintain a `[UInt: WindowSlot]` dictionary keyed by CGWindowID (the `windowHash` already stored in `WindowSlot`). Both `ResizeObserver.handle()` and `FocusObserver.executeDim()` can extract the CGWindowID from the callback element via `windowID(of:)` (already available via `_AXUIElementGetWindow`) and do an O(1) lookup.

### Implementation

Add to `ResizeObserver`:

```swift
var keysByHash: [UInt: WindowSlot] = [:]
```

In `observe()`: `keysByHash[key.windowHash] = key`
In `cleanup()`: `keysByHash.removeValue(forKey: key.windowHash)`

In `handle()`:

```swift
guard let wid = windowID(of: element),
      let key = keysByHash[UInt(wid)] else { return }
```

In `FocusObserver.executeDim()`:

```swift
guard let wid = windowID(of: axWindow),
      let key = ResizeObserver.shared.keysByHash[UInt(wid)] else {
    WindowOpacityService.shared.restoreAll()
    return
}
```

**Expected savings:** O(1) instead of O(n) per notification. Eliminates `CFEqual` calls entirely. Most impactful with many windows from the same PID (e.g., browser tabs).

---

## Improvement 5: Scope FocusObserver Search to PID (Low Impact, Very Low Complexity)

### Problem

`FocusObserver.executeDim()` (line 70) searches ALL elements to match the focused window:

```swift
guard let (key, _) = elements.first(where: { CFEqual($0.value, axWindow) }) else { ... }
```

The PID is already available from the callback. Only that PID's windows need to be checked.

### Solution

If Improvement 4 is not implemented, scope the search using `keysByPid`:

```swift
let elements = ResizeObserver.shared.elements
guard let keys = ResizeObserver.shared.keysByPid[pid],
      let key = keys.first(where: { elements[$0].map { CFEqual($0, axWindow) } == true })
else { ... }
```

If Improvement 4 is implemented, this becomes the O(1) `keysByHash` lookup and this improvement is subsumed.

**Expected savings:** Reduces search space from all windows to just one PID's windows on every focus change.

---

## Improvement 6: Skip Redundant SwapOverlay Updates (Low Impact, Very Low Complexity)

### Problem

During drag, `SwapOverlay.update()` is called on every mouse-move notification. It reads 2 AX attributes for the target window and calls `win.setFrame` + `win.order` (window server IPC), even when the drop target hasn't changed.

### Solution

`ResizeObserver` already tracks `lastDropTarget` and only updates `dropTargetEnteredAt` when the target changes. Move the overlay skip logic into `SwapOverlay.update()` itself — only perform AX reads and window updates when the target has actually changed:

```swift
private var currentTarget: DropTarget?

func update(dropTarget: DropTarget?, draggedWindow: AXUIElement, elements: [WindowSlot: AXUIElement]) {
    if dropTarget?.window == currentTarget?.window && dropTarget?.zone == currentTarget?.zone {
        return  // target unchanged — skip
    }
    currentTarget = dropTarget
    // ... existing update code ...
}
```

Reset `currentTarget` in `hide()`.

**Expected savings:** Eliminates 2 AX reads + 2 window server calls per mouse-move notification when hovering over the same target zone. During a typical drag, the cursor spends most of its time within a single zone.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/System/OnScreenWindowCache.swift` | **New file** — time-cached CGWindowList result shared across callers |
| `UnnamedWindowManager/Services/TileService.swift` | Modify — use `OnScreenWindowCache` in `visibleRootID()` |
| `UnnamedWindowManager/Services/ScrollingTileService.swift` | Modify — use `OnScreenWindowCache` in `visibleScrollingRootID()` |
| `UnnamedWindowManager/System/ReapplyHandler.swift` | Modify — use `OnScreenWindowCache` in `pruneOffScreenWindows`, use `computeFrames` in `findDropTarget` |
| `UnnamedWindowManager/System/LayoutService.swift` | Modify — add `computeFrames()`, add `lastApplied` cache, skip unchanged writes |
| `UnnamedWindowManager/Observation/ResizeObserver.swift` | Modify — add `keysByHash` reverse index, update `handle()` to use O(1) lookup |
| `UnnamedWindowManager/Observation/FocusObserver.swift` | Modify — use `keysByHash` for O(1) focused-window lookup |
| `UnnamedWindowManager/Observation/SwapOverlay.swift` | Modify — skip update when target unchanged |

---

## Implementation Steps

### 1. Create `OnScreenWindowCache`

New file with a time-cached `visibleHashes() -> Set<UInt>` method. Cache valid for 50ms. All existing `CGWindowListCopyWindowInfo` callers in `visibleRootID()`, `visibleScrollingRootID()`, and `onScreenWindowIDs()` switch to this shared cache.

### 2. Update `TileService.visibleRootID()` and `ScrollingTileService.visibleScrollingRootID()`

Replace inline `CGWindowListCopyWindowInfo` + parsing with `OnScreenWindowCache.visibleHashes()`.

### 3. Update `ReapplyHandler.onScreenWindowIDs()`

Replace with `OnScreenWindowCache.visibleHashes()`.

### 4. Add `computeFrames()` to `LayoutService`

Extract the tree-walk logic to compute `[WindowSlot: CGRect]` frames from the slot tree without AX calls. Use in `ReapplyHandler.findDropTarget()` instead of live AX reads.

### 5. Add skip-unchanged logic to `LayoutService.applyLayout`

Maintain `lastApplied` dictionary. Compare target position/size against cache before issuing AX writes. Clear entries on window removal.

### 6. Add `keysByHash` reverse index to `ResizeObserver`

Populate in `observe()`, remove in `cleanup()`. Update `handle()` to use `windowID(of:)` + dictionary lookup instead of `CFEqual` linear scan.

### 7. Update `FocusObserver.executeDim()` to use `keysByHash`

Replace `elements.first(where: { CFEqual(...) })` with `windowID(of:)` + `keysByHash` lookup.

### 8. Add target-change guard to `SwapOverlay`

Track `currentTarget`. Skip AX reads and window operations when target is the same. Reset on `hide()`.

---

## Key Technical Notes

- `OnScreenWindowCache` must only be accessed from the main thread (same as all AX observers). No synchronization needed.
- The 50ms cache TTL is chosen to cover the typical `reapplyAll` burst (all 5 calls happen within < 1ms) while ensuring space/display changes are detected within 1 frame at 20fps.
- `computeFrames()` returns frames in AX coordinates (top-left origin). `findDropTarget` must convert to AppKit coordinates for cursor comparison, same as the current code.
- The `lastApplied` cache must be cleared when Config changes (gap sizes) or screen resolution changes. Hook into `ScreenChangeObserver` and `Config.reload()`.
- `_AXUIElementGetWindow()` is a private SPI already used in `AXHelpers.swift`. Using it in the `handle()` callback is safe — it's a local call that extracts the cached CGWindowID from the AXUIElement struct, not IPC.
- `visibleRootID()` is called inside `store.queue.sync` blocks. `OnScreenWindowCache` must not itself acquire the queue (it doesn't — it only calls CGWindowList, which is independent).

---

## Verification

1. Tile 6 windows → resize one → only 2 AX writes should fire (the resized window), not 12
2. Drag a window across 3 other windows → overlay updates only when crossing zone boundaries, not on every pixel
3. Switch Spaces and return → layout reapplies correctly (cache TTL doesn't cause stale data)
4. Open 10+ windows from one app → focus changes remain instant (O(1) lookup via keysByHash)
5. Tile windows → `reapplyAll` should trigger 1 CGWindowList call (not 5) — verify via Logger output
6. Untile all windows → `lastApplied` cache is properly cleared (no stale entries)
