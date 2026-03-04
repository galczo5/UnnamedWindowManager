# Plan: 05_swap — Drag-to-Swap Snapped Windows

## Checklist

- [ ] Extend `SnapRegistry.swift` — add `swapSlots(key1:key2:)` helper
- [ ] Update `WindowSnapper.swift` — enhance `reapply` to detect drop-on-window and trigger swap; add `xRange(for:entries:screen:)` hit-test helper
- [ ] No changes to `ResizeObserver.swift` or UI — the moved-notification path already calls `reapply`

---

## Context

After 04_horizontal_resize, snapped windows each keep their own width and the layout reflows on resize. Windows are ordered left-to-right by ascending slot index.

This plan adds **drag-to-swap**: when the user drags a snapped window and releases it over another snapped window's horizontal zone, the two windows exchange slot indices. After the swap, `reapplyAll()` repositions both (and any windows between them) using each window's stored width. This means the two windows trade visual positions even if they have different widths.

---

## Files to modify

| File | Action |
|---|---|
| `UnnamedWindowManager/SnapRegistry.swift` | Add `swapSlots(key1:key2:)` |
| `UnnamedWindowManager/WindowSnapper.swift` | Detect drop target in `reapply`; add `xRange` helper |

---

## Implementation Steps

### 1. `SnapRegistry` — `swapSlots`

Add a single method that atomically exchanges the `slot` values of two entries:

```swift
func swapSlots(_ key1: SnapKey, _ key2: SnapKey) {
    queue.async(flags: .barrier) {
        guard var e1 = self.store[key1], var e2 = self.store[key2] else { return }
        let tmp = e1.slot
        e1.slot = e2.slot
        e2.slot = tmp
        self.store[key1] = e1
        self.store[key2] = e2
    }
}
```

No other changes to `SnapRegistry`.

---

### 2. `WindowSnapper` — hit-test helper

Add a pure helper that computes the horizontal extent `[minX, maxX]` of a slot position given the current entry list and screen. This mirrors the X-offset math already used in `applyPosition`:

```swift
private static func xRange(
    for targetKey: SnapKey,
    entries: [(key: SnapKey, entry: SnapEntry)],
    screen: NSScreen
) -> ClosedRange<CGFloat>? {
    guard let myEntry = entries.first(where: { $0.key == targetKey })?.entry else { return nil }
    let visible = screen.visibleFrame
    let gap: CGFloat = 10

    var xOffset = visible.minX + gap
    for item in entries {
        if item.entry.slot == myEntry.slot { break }
        xOffset += item.entry.width + gap
    }
    return xOffset...(xOffset + myEntry.width)
}
```

---

### 3. `WindowSnapper` — swap-aware `reapply`

Replace the current `reapply(window:key:)` body with swap detection before the position restore:

```swift
static func reapply(window: AXUIElement, key: SnapKey) {
    guard SnapRegistry.shared.entry(for: key) != nil else { return }
    guard let screen = NSScreen.main else { return }

    let entries = SnapRegistry.shared.allEntries()

    // Read where the user dropped the window.
    guard let droppedSize = readSize(of: window),
          let droppedOrigin = readOrigin(of: window) else {
        applyPosition(to: window, key: key, entries: entries, screen: screen)
        return
    }

    let droppedMidX = droppedOrigin.x + droppedSize.width / 2

    // Check if the dragged window's mid-X lands inside another tracked window's zone.
    if let targetKey = entries.first(where: { item in
        item.key != key &&
        xRange(for: item.key, entries: entries, screen: screen)?.contains(droppedMidX) == true
    })?.key {
        // Swap slots and reflow the whole layout.
        SnapRegistry.shared.swapSlots(key, targetKey)
        reapplyAll()
    } else {
        // No target hit — restore original position.
        applyPosition(to: window, key: key, entries: entries, screen: screen)
    }
}
```

`readOrigin` is the AX equivalent of `readSize` — add it alongside:

```swift
internal static func readOrigin(of window: AXUIElement) -> CGPoint? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &ref) == .success,
          let axVal = ref,
          CFGetTypeID(axVal) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    AXValueGetValue(axVal as! AXValue, .cgPoint, &point)
    return point
}
```

> **AX coordinate note**: `kAXPositionAttribute` returns a point in the flipped AX coordinate space (top-left origin). `droppedMidX` is purely in the X axis, which is the same direction in both coordinate systems, so no conversion is needed for the horizontal hit-test.

---

### 4. Why no position adjustment beyond `reapplyAll()`

After `swapSlots`, the two windows' slot indices are exchanged. `reapplyAll()` iterates `allEntries()` (sorted ascending by slot) and recomputes each window's X offset as the sum of widths of all lower-slot windows plus gaps. Because each window keeps its own stored width, the layout correctly reflects the new slot order regardless of width differences.

Example:
- Before swap: A (slot=0, width=800) | B (slot=1, width=600)
- User drags A over B's zone.
- After `swapSlots`: A (slot=1, width=800), B (slot=0, width=600)
- `reapplyAll()` places B at `gap`, then A at `gap + 600 + gap`.
- Result: B is now leftmost at its narrower width; A is to the right at its wider width.

No manual width adjustment or special-casing is required.

---

## Key Technical Notes

- **Hit-test uses mid-X of the dragged window**: using the center prevents accidental swaps caused by minimal overlap at zone edges.
- **Debounce / in-flight guard**: `reapplyAll()` already marks all keys in-flight before repositioning and clears them after, so the moved notifications fired by the reapply do not re-enter `reapply`.
- **Swap is slot-only**: widths and heights stored in `SnapEntry` are untouched; only the `slot` field is exchanged.
- **Non-snapped drop**: if the user drops the window somewhere with no overlap against any other window's zone, existing behavior is preserved — the window snaps back to its own slot position.
- **Single other-window target**: if `droppedMidX` somehow falls within two zones (e.g. during rapid resize-then-drag), `first(where:)` picks the first match in slot order, which is the closest leftward neighbour — an acceptable tie-breaker.
- **`readOrigin` visibility**: `internal` (not `private`) so it can be reused by `ResizeObserver` if needed in future plans.

---

## Verification

1. Snap Finder (800 px wide) → slot 0. Snap Safari (600 px wide) → slot 1. Layout: Finder | Safari.
2. Drag Finder over Safari's zone and release → slots swap. Layout: Safari | Finder. Both windows reposition correctly with their own widths.
3. Drag Safari back over Finder's new zone → slots swap again. Layout returns to original: Finder | Safari.
4. Drag a snapped window to empty screen space (no other window zone) → window snaps back to its original slot (no swap).
5. Snap a third window Terminal → slot 2. Drag the middle window (slot 1) over slot 2's zone → only those two swap; slot 0 window is unaffected and stays in place.
6. Resize any window after a swap → `reapplyAll()` reflows correctly from the swapped slot order.
