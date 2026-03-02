# Plan: 07_drop_zones — Left / Center / Right Drop Zones

## Checklist

- [ ] Add `DropZone` enum and `DropTarget` struct to `SnapRegistry.swift`
- [ ] Add `moveSlot(_:before:)` and `moveSlot(_:after:)` to `SnapRegistry.swift`
- [ ] Replace `findSwapTarget` with `findDropTarget` in `SnapLayout.swift`; add `gapFrame` helpers
- [ ] Update `ResizeObserver+SwapOverlay.swift` to draw gap rectangle for left/right zones
- [ ] Update `ResizeObserver+Reapply.swift` to dispatch insert vs swap based on drop zone

---

## Context

After 06_constraints, windows have size limits and the swap gesture replaces two windows' slot indices. The current hit-test treats the entire horizontal extent of a target window as a single swap zone.

This plan divides each window into **three drop zones** and changes the drop action depending on which zone is hit:

| Zone | Width | Hover overlay | Drop action |
|---|---|---|---|
| **Left** | first 10 % of window width | Rectangle in the gap **left** of target | Insert dragged window immediately to the **left** of target |
| **Center** | middle 80 % | Rectangle **over** target (existing behavior) | Swap dragged and target |
| **Right** | last 10 % of window width | Rectangle in the gap **right** of target | Insert dragged window immediately to the **right** of target |

The insert operation requires renumbering slots rather than just swapping two values.

---

## Files to modify

| File | Action |
|---|---|
| `UnnamedWindowManager/Model/SnapRegistry.swift` | Add `DropZone`, `DropTarget`; add `moveSlot(_:before:)` and `moveSlot(_:after:)` |
| `UnnamedWindowManager/Snapping/SnapLayout.swift` | Replace `findSwapTarget` with `findDropTarget`; add zone hit-test math and gap frame helpers |
| `UnnamedWindowManager/Observation/ResizeObserver+SwapOverlay.swift` | Accept `DropTarget?`; choose gap or window overlay frame |
| `UnnamedWindowManager/Observation/ResizeObserver+Reapply.swift` | Use `findDropTarget` and dispatch to `moveSlot` or `swapSlots` |

---

## Implementation Steps

### 1. `SnapRegistry.swift` — new types

Add alongside `SnapKey` and `SnapEntry`:

```swift
enum DropZone {
    case left    // insert dragged window before target
    case center  // swap dragged and target
    case right   // insert dragged window after target
}

struct DropTarget {
    let key:  SnapKey
    let zone: DropZone
}
```

---

### 2. `SnapRegistry.swift` — `moveSlot` helpers

Add two methods that reorder the slot sequence without touching widths or heights:

```swift
/// Moves `key` to the slot immediately before `targetKey`, shifting others to fill.
func moveSlot(_ key: SnapKey, before targetKey: SnapKey) {
    queue.sync(flags: .barrier) {
        var ordered = self.store
            .map { (key: $0.key, slot: $0.value.slot) }
            .sorted { $0.slot < $1.slot }
            .map(\.key)

        guard ordered.contains(key), ordered.contains(targetKey), key != targetKey else { return }

        ordered.removeAll { $0 == key }
        let insertIdx = ordered.firstIndex(of: targetKey)!
        ordered.insert(key, at: insertIdx)

        for (i, k) in ordered.enumerated() {
            self.store[k]?.slot = i
        }
    }
}

/// Moves `key` to the slot immediately after `targetKey`, shifting others to fill.
func moveSlot(_ key: SnapKey, after targetKey: SnapKey) {
    queue.sync(flags: .barrier) {
        var ordered = self.store
            .map { (key: $0.key, slot: $0.value.slot) }
            .sorted { $0.slot < $1.slot }
            .map(\.key)

        guard ordered.contains(key), ordered.contains(targetKey), key != targetKey else { return }

        ordered.removeAll { $0 == key }
        let insertIdx = ordered.firstIndex(of: targetKey)!
        ordered.insert(key, at: insertIdx + 1)

        for (i, k) in ordered.enumerated() {
            self.store[k]?.slot = i
        }
    }
}
```

Both methods use `queue.sync(flags: .barrier)` (same as `swapSlots`) to atomically mutate the store.

---

### 3. `SnapLayout.swift` — `findDropTarget` and gap frame helpers

Replace `findSwapTarget` with `findDropTarget`:

```swift
/// Returns the drop target (key + zone) for the window currently being dragged,
/// or `nil` if the dragged window is not over any other snapped window.
static func findDropTarget(for key: SnapKey, window: AXUIElement) -> DropTarget? {
    guard let screen = NSScreen.main,
          let droppedSize   = readSize(of: window),
          let droppedOrigin = readOrigin(of: window) else { return nil }

    let droppedMidX = droppedOrigin.x + droppedSize.width / 2
    let entries = SnapRegistry.shared.allEntries()

    for item in entries where item.key != key {
        guard let range = xRange(for: item.key, entries: entries, screen: screen) else { continue }
        guard range.contains(droppedMidX) else { continue }

        let windowWidth = range.upperBound - range.lowerBound
        let leftEnd   = range.lowerBound + windowWidth * 0.10
        let rightStart = range.lowerBound + windowWidth * 0.90

        let zone: DropZone
        if droppedMidX < leftEnd {
            zone = .left
        } else if droppedMidX > rightStart {
            zone = .right
        } else {
            zone = .center
        }

        return DropTarget(key: item.key, zone: zone)
    }
    return nil
}
```

Add two helpers that compute the gap overlay rectangle in **AppKit coordinates** (bottom-left origin):

```swift
/// Frame of the gap to the left of `targetKey`'s window, in AppKit screen coordinates.
static func leftGapFrame(for targetKey: SnapKey, screen: NSScreen) -> CGRect? {
    let entries = SnapRegistry.shared.allEntries()
    guard let range  = xRange(for: targetKey, entries: entries, screen: screen),
          let entry  = entries.first(where: { $0.key == targetKey })?.entry else { return nil }

    let primaryHeight = NSScreen.screens[0].frame.height
    let axY           = primaryHeight - screen.visibleFrame.maxY + Config.gap
    let appKitY       = primaryHeight - axY - entry.height

    return CGRect(
        x:      range.lowerBound - Config.gap,
        y:      appKitY,
        width:  Config.gap,
        height: entry.height
    )
}

/// Frame of the gap to the right of `targetKey`'s window, in AppKit screen coordinates.
static func rightGapFrame(for targetKey: SnapKey, screen: NSScreen) -> CGRect? {
    let entries = SnapRegistry.shared.allEntries()
    guard let range = xRange(for: targetKey, entries: entries, screen: screen),
          let entry = entries.first(where: { $0.key == targetKey })?.entry else { return nil }

    let primaryHeight = NSScreen.screens[0].frame.height
    let axY           = primaryHeight - screen.visibleFrame.maxY + Config.gap
    let appKitY       = primaryHeight - axY - entry.height

    return CGRect(
        x:      range.upperBound,
        y:      appKitY,
        width:  Config.gap,
        height: entry.height
    )
}
```

> `xRange` already returns `[xOffset, xOffset + width]`, so `range.lowerBound` is the window's left AX-X and `range.upperBound` is its right AX-X. AX X coordinates match AppKit X (same left-to-right direction), so no horizontal flip is needed.

---

### 4. `ResizeObserver+SwapOverlay.swift` — zone-aware overlay

Replace `updateSwapOverlay(for:draggedWindow:)` to consume a `DropTarget` directly, and choose between a gap frame and a window frame:

```swift
func updateSwapOverlay(for draggedKey: SnapKey, draggedWindow: AXUIElement) {
    guard let screen = NSScreen.main,
          let target = WindowSnapper.findDropTarget(for: draggedKey, window: draggedWindow) else {
        hideSwapOverlay()
        return
    }

    let frame: CGRect?
    switch target.zone {
    case .left:
        frame = WindowSnapper.leftGapFrame(for: target.key, screen: screen)
    case .right:
        frame = WindowSnapper.rightGapFrame(for: target.key, screen: screen)
    case .center:
        // Existing behavior: overlay over the whole target window.
        guard let targetElement = elements[target.key],
              let axOrigin = WindowSnapper.readOrigin(of: targetElement),
              let axSize   = WindowSnapper.readSize(of: targetElement) else {
            hideSwapOverlay()
            return
        }
        let screenHeight = NSScreen.screens[0].frame.height
        let appKitOrigin = CGPoint(x: axOrigin.x, y: screenHeight - axOrigin.y - axSize.height)
        frame = CGRect(origin: appKitOrigin, size: axSize)
    }

    guard let overlayFrame = frame else { hideSwapOverlay(); return }

    let draggedWindowNumber = WindowSnapper.windowID(of: draggedWindow).map(Int.init)
    showSwapOverlay(frame: overlayFrame, belowWindow: draggedWindowNumber)
}
```

`showSwapOverlay(frame:belowWindow:)` and `hideSwapOverlay()` are unchanged.

---

### 5. `ResizeObserver+Reapply.swift` — dispatch insert vs swap

Replace the `findSwapTarget` call and the resulting action block:

```swift
// Before (in the non-resize branch):
if let targetKey = WindowSnapper.findSwapTarget(for: key, window: storedElement) {
    SnapRegistry.shared.swapSlots(key, targetKey)
    ...
}

// After:
if let target = WindowSnapper.findDropTarget(for: key, window: storedElement) {
    switch target.zone {
    case .left:
        SnapRegistry.shared.moveSlot(key, before: target.key)
    case .right:
        SnapRegistry.shared.moveSlot(key, after: target.key)
    case .center:
        SnapRegistry.shared.swapSlots(key, target.key)
    }
    let allKeys = Set(SnapRegistry.shared.allEntries().map(\.key))
    self.reapplying.formUnion(allKeys)
    WindowSnapper.reapplyAll()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.reapplying.subtract(allKeys)
    }
} else {
    // Restore position (and stored size) of the moved window only.
    ...
}
```

---

## Key Technical Notes

- **Zone boundaries are computed from the target window's extent**, not the dragged window's size. The 10 % thresholds are relative to the target window's stored width.
- **`moveSlot` reassigns all slot indices (0, 1, 2, …) on every call.** This is safe and keeps slots contiguous. With at most a handful of snapped windows, the linear scan is negligible.
- **`moveSlot` is idempotent for a no-op move** (e.g., dragging A before B when A is already left of B and adjacent). The slot sequence is rewritten to the same values — `reapplyAll()` then repositions windows to their current positions unchanged.
- **`swapSlots` is kept unchanged** for the center zone. No need to change its implementation.
- **Gap overlay frame derivation**: the gap rectangles are derived from `xRange` (registry data), not from reading AX position of the target window. This avoids a second AX call and is consistent with the layout math used in `applyPosition`.
- **AX X = AppKit X**: the horizontal axis is identical in both coordinate systems (left-to-right), so no X flip is needed for the gap overlay frames.
- **The overlay `belowWindow` ordering** still uses the dragged window's `windowID` (unchanged), so the indicator appears beneath the dragged window in all three zones.
- **`findDropTarget` replaces `findSwapTarget` entirely**: all call sites (`updateSwapOverlay` and `scheduleReapplyWhenMouseUp`) are updated. The old function is removed.

---

## Verification

1. **Left zone insert**: Snap A, B, C. Drag C over B's left zone (hover over leftmost 10 % of B). Overlay appears in gap between A and B. Release → layout becomes A | C | B. C is now in the middle.
2. **Right zone insert**: With A | C | B from above, drag A over C's right zone (rightmost 10 % of C). Overlay appears in gap between C and B. Release → layout becomes C | A | B.
3. **Center zone swap** (regression): Drag B over C's center zone. Overlay covers C entirely. Release → B and C swap. Layout becomes C | A | B (slots exchanged).
4. **Leftmost window, left zone**: Drag B over A's left zone. Overlay appears between screen left edge and A. Release → B becomes the leftmost window.
5. **Rightmost window, right zone**: With three windows, drag the leftmost over the rightmost's right zone. Overlay appears to the right of the last window. Release → dragged window becomes the new rightmost.
6. **No-op insert**: Drag A over B's left zone when A is already immediately left of B. Overlay appears in the gap. Release → layout unchanged; `reapplyAll` restores positions.
7. **Empty space drop** (regression): Drag a snapped window to an empty area of the screen. No overlay. Release → window snaps back to its slot.
8. **Resize after insert** (regression): After any insert, resize a window → `reapplyAll` reflows correctly from the new slot order.
