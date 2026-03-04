# Plan: 11_new_drop_zones — Redesign Drop Zones

## Checklist

- [x] Update `DropZone` enum: add `.top` case in `ManagedTypes.swift`
- [x] Update `DropTarget` struct: add `windowIndex` field in `ManagedTypes.swift`
- [x] Add `insertSlotBefore(_:targetSlot:screen:)` and `insertSlotAfter(_:targetSlot:screen:)` to `ManagedSlotRegistry+SlotMutations.swift`
- [x] Add `insertWindowTop(_:intoSlot:screen:)` to `ManagedSlotRegistry+SlotMutations.swift`; rename existing `splitVertical` → `insertWindowBottom`
- [x] Replace `swapSlots` and `swapWindowsInSlot` with `swapWindows(_:with:)` in `ManagedSlotRegistry+SlotMutations.swift`
- [x] Rewrite `findDropTarget` hit-test in `SnapLayout.swift` — 5 zones per slot, center zone identifies individual window
- [x] Add `topSplitOverlayFrame` helper in `SnapLayout.swift`
- [x] Update `ResizeObserver+SwapOverlay.swift` — handle `.top` zone overlay; center overlay targets individual window
- [x] Update `ResizeObserver+Reapply.swift` — dispatch to new mutation methods
- [x] Update `Config.swift` — add `dropZoneTopFraction`

---

## Summary

Replace the current drop zone system with 5 zones per slot:

| Zone | Region | Drop action |
|------|--------|-------------|
| **Left** | first 10 % of slot width | **Create new slot before** target; move dragged window there (width = source slot width, height = 100 %) |
| **Right** | last 10 % of slot width | **Create new slot after** target; same sizing rules |
| **Top** | top 20 % of slot height (inside center band) | Add dragged window as **first** in target slot's window list; equalize heights |
| **Bottom** | bottom 20 % of slot height (inside center band) | Add dragged window as **last** in target slot's window list; equalize heights |
| **Center** | remaining area | **Swap** dragged window with the specific target window; heights are swapped too |

### Key behavior changes from current implementation

1. **Left/Right zones no longer move the whole source slot** — they extract the dragged window from its source slot, create a brand-new slot at the insert position, and place the window in it. The new slot's width equals the **source** slot's width. The window's height is set to 100 % of the visible screen. If the source slot becomes empty, it is removed.
2. **Top zone is new** — mirrors bottom, but inserts the window at position 0 in the target slot's window list.
3. **Bottom zone** — behavior is the same as the current `insertWindowBottom` (append to end, equalize heights), but the limit of max 2 windows per slot is **removed** (any slot can receive more windows).
4. **Center zone swaps individual windows** — instead of swapping entire slots, the hit-test identifies the specific window under the cursor. The two windows exchange positions (slot + index) and their heights are swapped. Works both across slots and within the same slot.

---

## Files to modify

| File | Action |
|------|--------|
| `ManagedTypes.swift` | Add `.top` case to `DropZone`; add `windowIndex` to `DropTarget` |
| `ManagedSlotRegistry+SlotMutations.swift` | Add `insertSlotBefore`, `insertSlotAfter`, `insertWindowTop`, `swapWindows`; rename `splitVertical` → `insertWindowBottom`; remove `moveSlot(containing:before/after:)`, `swapSlots`, `swapWindowsInSlot` |
| `SnapLayout.swift` | Rewrite `findDropTarget` hit-test; add `topSplitOverlayFrame` |
| `ResizeObserver+SwapOverlay.swift` | Handle `.top` overlay |
| `ResizeObserver+Reapply.swift` | Dispatch to new mutation methods |
| `Config.swift` | Add `dropZoneTopFraction` |

---

## Implementation Steps

### 1. `ManagedTypes.swift` — update types

```swift
enum DropZone {
    case left    // create new slot before target
    case top     // add dragged window as first in target slot
    case center  // swap individual windows
    case bottom  // add dragged window as last in target slot
    case right   // create new slot after target
}

/// A drop target: which slot, which window within the slot, and which zone.
struct DropTarget {
    let slotIndex: Int
    let windowIndex: Int   // index of the specific window within the slot
    let zone: DropZone
}
```

`windowIndex` is used by the `.center` zone to identify the exact target window. For `.left`/`.right`/`.top`/`.bottom`, the value is ignored (can be 0).

---

### 2. `Config.swift` — add top fraction

```swift
/// Fraction of a slot's height (from the top) that activates the top vertical-split drop zone.
static let dropZoneTopFraction: CGFloat = 0.20
```

---

### 3. `ManagedSlotRegistry+SlotMutations.swift` — new mutations

#### `insertSlotBefore(_:targetSlot:screen:)` — Left zone

Extracts the dragged window from its source slot. Creates a new `ManagedSlot` with:
- `width` = source slot's width
- single window with `height` = visible screen height minus 2 gaps (full height)

Inserts the new slot **before** `targetSlotIndex`. If the source slot becomes empty, it is removed. If windows remain in the source slot, their heights are equalized.

```swift
/// Extracts `draggedKey` from its slot and creates a new slot before `targetSlotIndex`.
func insertSlotBefore(_ draggedKey: ManagedWindow, targetSlot targetSlotIndex: Int, screen: NSScreen) {
    let visible = screen.visibleFrame
    let fullH = visible.height - Config.gap * 2

    queue.sync(flags: .barrier) {
        guard targetSlotIndex >= 0, targetSlotIndex < self.slots.count else { return }
        guard let srcIdx = self.indexOfSlot(containing: draggedKey) else { return }
        guard let srcWinIdx = self.slots[srcIdx].windows.firstIndex(of: draggedKey) else { return }

        let sourceWidth = self.slots[srcIdx].width
        var draggedWindow = self.slots[srcIdx].windows.remove(at: srcWinIdx)
        draggedWindow.height = fullH

        // Remove source slot if empty; adjust target index.
        var adjustedTarget = targetSlotIndex
        if self.slots[srcIdx].windows.isEmpty {
            self.slots.remove(at: srcIdx)
            if srcIdx < adjustedTarget { adjustedTarget -= 1 }
        } else {
            self.equalizeHeights(inSlot: srcIdx, visibleHeight: visible.height)
        }

        let newSlot = ManagedSlot(width: sourceWidth, windows: [draggedWindow])
        self.slots.insert(newSlot, at: adjustedTarget)
    }
}
```

#### `insertSlotAfter(_:targetSlot:screen:)` — Right zone

Same as above, but inserts **after** `targetSlotIndex`.

```swift
/// Extracts `draggedKey` from its slot and creates a new slot after `targetSlotIndex`.
func insertSlotAfter(_ draggedKey: ManagedWindow, targetSlot targetSlotIndex: Int, screen: NSScreen) {
    let visible = screen.visibleFrame
    let fullH = visible.height - Config.gap * 2

    queue.sync(flags: .barrier) {
        guard targetSlotIndex >= 0, targetSlotIndex < self.slots.count else { return }
        guard let srcIdx = self.indexOfSlot(containing: draggedKey) else { return }
        guard let srcWinIdx = self.slots[srcIdx].windows.firstIndex(of: draggedKey) else { return }

        let sourceWidth = self.slots[srcIdx].width
        var draggedWindow = self.slots[srcIdx].windows.remove(at: srcWinIdx)
        draggedWindow.height = fullH

        // Remove source slot if empty; adjust target index.
        var adjustedTarget = targetSlotIndex
        if self.slots[srcIdx].windows.isEmpty {
            self.slots.remove(at: srcIdx)
            if srcIdx < adjustedTarget { adjustedTarget -= 1 }
        } else {
            self.equalizeHeights(inSlot: srcIdx, visibleHeight: visible.height)
        }

        let newSlot = ManagedSlot(width: sourceWidth, windows: [draggedWindow])
        let insertIdx = adjustedTarget + 1
        self.slots.insert(newSlot, at: min(insertIdx, self.slots.count))
    }
}
```

#### `insertWindowTop(_:intoSlot:screen:)` — Top zone

Extracts the dragged window from its source slot and inserts it as the **first** window (index 0) in the target slot. All windows in the target slot (including the newly inserted one) have their heights equalized so the sum equals 100 % of the visible screen. If the source slot still has windows, their heights are also equalized.

```swift
/// Moves `draggedKey` into `targetIndex` slot as the first window.
/// Equalizes heights of all windows in both source and target slots.
func insertWindowTop(_ draggedKey: ManagedWindow, intoSlot targetIndex: Int, screen: NSScreen) {
    let visible = screen.visibleFrame

    queue.sync(flags: .barrier) {
        guard targetIndex >= 0, targetIndex < self.slots.count else { return }
        guard let srcIdx = self.indexOfSlot(containing: draggedKey) else { return }
        guard let srcWinIdx = self.slots[srcIdx].windows.firstIndex(of: draggedKey) else { return }

        let draggedWindow = self.slots[srcIdx].windows.remove(at: srcWinIdx)

        var adjustedTarget = targetIndex
        if self.slots[srcIdx].windows.isEmpty {
            self.slots.remove(at: srcIdx)
            if srcIdx < adjustedTarget { adjustedTarget -= 1 }
        } else {
            self.equalizeHeights(inSlot: srcIdx, visibleHeight: visible.height)
        }

        guard adjustedTarget >= 0, adjustedTarget < self.slots.count else { return }

        var moved = draggedWindow
        let windowCount = CGFloat(self.slots[adjustedTarget].windows.count + 1)
        let perWindowH = (visible.height - Config.gap * (windowCount + 1)) / windowCount
        moved.height = perWindowH

        self.slots[adjustedTarget].windows.insert(moved, at: 0)

        // Equalize all windows in the target slot.
        for wi in self.slots[adjustedTarget].windows.indices {
            self.slots[adjustedTarget].windows[wi].height = perWindowH
        }
    }
}
```

#### `insertWindowBottom(_:intoSlot:screen:)` — Bottom zone

Rename existing `splitVertical` → `insertWindowBottom`. Same logic — appends the window as the **last** in the target slot. All windows in the target slot have their heights equalized so the sum equals 100 % of the visible screen. If the source slot still has windows, their heights are also equalized.

#### Private helper: `equalizeHeights`

```swift
/// Equalizes window heights in a slot. Must be called inside a barrier.
private func equalizeHeights(inSlot slotIndex: Int, visibleHeight: CGFloat) {
    let count = CGFloat(self.slots[slotIndex].windows.count)
    guard count > 0 else { return }
    let perWindowH = (visibleHeight - Config.gap * (count + 1)) / count
    for wi in self.slots[slotIndex].windows.indices {
        self.slots[slotIndex].windows[wi].height = perWindowH
    }
}
```

#### `swapWindows(_:with:)` — Center zone

Replaces both `swapSlots` and `swapWindowsInSlot`. Swaps two individual windows by their (slotIndex, windowIndex) positions. Heights are swapped along with the windows — each window keeps its original height and moves to the other's position.

Works both across different slots and within the same slot.

```swift
/// Swaps two individual windows. Each window moves to the other's (slot, index) position.
/// Heights travel with the windows (i.e. heights are swapped).
func swapWindows(
    _ a: (slotIndex: Int, windowIndex: Int),
    with b: (slotIndex: Int, windowIndex: Int)
) {
    queue.sync(flags: .barrier) {
        guard a.slotIndex >= 0, a.slotIndex < self.slots.count,
              b.slotIndex >= 0, b.slotIndex < self.slots.count,
              a.windowIndex >= 0, a.windowIndex < self.slots[a.slotIndex].windows.count,
              b.windowIndex >= 0, b.windowIndex < self.slots[b.slotIndex].windows.count
        else { return }

        // Same slot — simple array swap.
        if a.slotIndex == b.slotIndex {
            self.slots[a.slotIndex].windows.swapAt(a.windowIndex, b.windowIndex)
            return
        }

        // Different slots — swap windows and their heights.
        let winA = self.slots[a.slotIndex].windows[a.windowIndex]
        let winB = self.slots[b.slotIndex].windows[b.windowIndex]
        self.slots[a.slotIndex].windows[a.windowIndex] = winB
        self.slots[b.slotIndex].windows[b.windowIndex] = winA
    }
}
```

Since `ManagedWindow.height` is part of the struct, swapping the entire structs naturally swaps the heights too.

#### Remove old methods

- **`moveSlot(containing:before:)` and `moveSlot(containing:after:)`** — replaced by `insertSlotBefore` / `insertSlotAfter`.
- **`swapSlots(_:_:)` and `swapWindowsInSlot(_:_:_:)`** — replaced by `swapWindows(_:with:)`.

---

### 4. `SnapLayout.swift` — rewrite `findDropTarget`

The new hit-test order within a slot's X range:

1. Cursor in left 10 % → `.left`
2. Cursor in right 10 % → `.right`
3. Cursor in top 20 % (of remaining center band) → `.top`
4. Cursor in bottom 20 % (of remaining center band) → `.bottom`
5. Otherwise → `.center`

```swift
static func findDropTarget(forWindowIn sourceSlotIndex: Int) -> DropTarget? {
    guard let screen = NSScreen.main else { return nil }

    let cursorX       = NSEvent.mouseLocation.x
    let cursorY       = NSEvent.mouseLocation.y   // AppKit coords (bottom-left origin)
    let primaryHeight = NSScreen.screens[0].frame.height
    let slots         = ManagedSlotRegistry.shared.allSlots()

    for (si, slot) in slots.enumerated() where si != sourceSlotIndex {
        guard let range = xRange(forSlot: si, slots: slots, screen: screen) else { continue }
        guard range.contains(cursorX) else { continue }

        let slotWidth  = range.upperBound - range.lowerBound
        let leftEnd    = range.lowerBound + slotWidth * Config.dropZoneFraction
        let rightStart = range.lowerBound + slotWidth * (1 - Config.dropZoneFraction)

        // Left / right edges — checked first.
        if cursorX < leftEnd   { return DropTarget(slotIndex: si, windowIndex: 0, zone: .left)  }
        if cursorX > rightStart { return DropTarget(slotIndex: si, windowIndex: 0, zone: .right) }

        // Vertical zones within the center band.
        let totalHeight = slot.windows.reduce(CGFloat(0)) { $0 + $1.height }
            + Config.gap * CGFloat(slot.windows.count - 1)
        let axY         = primaryHeight - screen.visibleFrame.maxY + Config.gap
        let appKitTop   = primaryHeight - axY                // top of slot in AppKit coords
        let appKitBottom = appKitTop - totalHeight

        let topZoneBound    = appKitTop - totalHeight * Config.dropZoneTopFraction
        let bottomZoneBound = appKitBottom + totalHeight * Config.dropZoneBottomFraction

        if cursorY >= topZoneBound    { return DropTarget(slotIndex: si, windowIndex: 0, zone: .top) }
        if cursorY <= bottomZoneBound { return DropTarget(slotIndex: si, windowIndex: 0, zone: .bottom) }

        // Center zone — identify the specific window under the cursor.
        let windowIndex = windowIndexAtCursor(
            cursorY: cursorY, slot: slot,
            slotTopAX: primaryHeight - screen.visibleFrame.maxY + Config.gap,
            primaryHeight: primaryHeight
        )
        return DropTarget(slotIndex: si, windowIndex: windowIndex, zone: .center)
    }
    return nil
}

/// Returns the index of the window under `cursorY` (AppKit coords) within the slot.
/// Falls back to the last window if the cursor is below all windows.
private static func windowIndexAtCursor(
    cursorY: CGFloat,
    slot: ManagedSlot,
    slotTopAX: CGFloat,
    primaryHeight: CGFloat
) -> Int {
    var axY = slotTopAX
    for (wi, window) in slot.windows.enumerated() {
        let windowBottom = axY + window.height
        let appKitTop    = primaryHeight - axY
        let appKitBottom = primaryHeight - windowBottom

        if cursorY <= appKitTop && cursorY >= appKitBottom {
            return wi
        }
        axY = windowBottom + Config.gap
    }
    return max(slot.windows.count - 1, 0)
}
```

#### Add `topSplitOverlayFrame`

Mirrors `bottomSplitOverlayFrame` but positioned at the top of the slot.

```swift
/// Frame of the upper-portion split rectangle, in AppKit screen coordinates.
static func topSplitOverlayFrame(forSlot slotIndex: Int, slots: [ManagedSlot], screen: NSScreen) -> CGRect? {
    guard let range = xRange(forSlot: slotIndex, slots: slots, screen: screen) else { return nil }
    let slot = slots[slotIndex]
    let visible = screen.visibleFrame
    let windowCount = CGFloat(slot.windows.count + 1)
    let perWindowH  = (visible.height - Config.gap * (windowCount + 1)) / windowCount

    let primaryHeight = NSScreen.screens[0].frame.height
    let axY = primaryHeight - visible.maxY + Config.gap
    let appKitTop = primaryHeight - axY - perWindowH

    return CGRect(
        x:      range.lowerBound,
        y:      appKitTop,
        width:  slot.width,
        height: perWindowH
    )
}
```

---

### 5. `ResizeObserver+SwapOverlay.swift` — handle `.top` and per-window `.center`

Add `.top` case and update `.center` to highlight the specific target window:

```swift
let frame: CGRect?
switch target.zone {
case .left:
    frame = WindowSnapper.leftGapFrame(forSlot: target.slotIndex, slots: slots, screen: screen)
case .right:
    frame = WindowSnapper.rightGapFrame(forSlot: target.slotIndex, slots: slots, screen: screen)
case .top:
    frame = WindowSnapper.topSplitOverlayFrame(forSlot: target.slotIndex, slots: slots, screen: screen)
case .bottom:
    frame = WindowSnapper.bottomSplitOverlayFrame(forSlot: target.slotIndex, slots: slots, screen: screen)
case .center:
    // Overlay over the specific target window (not the whole slot).
    let targetSlot = slots[target.slotIndex]
    let targetWindow = targetSlot.windows[target.windowIndex]
    guard let targetElement = elements[targetWindow],
          let axOrigin = WindowSnapper.readOrigin(of: targetElement),
          let axSize   = WindowSnapper.readSize(of: targetElement) else {
        hideSwapOverlay()
        return
    }
    let screenHeight = NSScreen.screens[0].frame.height
    let appKitOrigin = CGPoint(x: axOrigin.x, y: screenHeight - axOrigin.y - axSize.height)
    frame = CGRect(origin: appKitOrigin, size: axSize)
}
```

---

### 6. `ResizeObserver+Reapply.swift` — dispatch to new methods

```swift
if let target = WindowSnapper.findDropTarget(forWindowIn: sourceSlotIndex) {
    switch target.zone {
    case .left:
        ManagedSlotRegistry.shared.insertSlotBefore(key, targetSlot: target.slotIndex, screen: screen)
    case .right:
        ManagedSlotRegistry.shared.insertSlotAfter(key, targetSlot: target.slotIndex, screen: screen)
    case .top:
        ManagedSlotRegistry.shared.insertWindowTop(key, intoSlot: target.slotIndex, screen: screen)
    case .bottom:
        ManagedSlotRegistry.shared.insertWindowBottom(key, intoSlot: target.slotIndex, screen: screen)
    case .center:
        guard let srcWinIdx = ManagedSlotRegistry.shared.windowIndex(for: key, inSlot: sourceSlotIndex) else { break }
        ManagedSlotRegistry.shared.swapWindows(
            (slotIndex: sourceSlotIndex, windowIndex: srcWinIdx),
            with: (slotIndex: target.slotIndex, windowIndex: target.windowIndex)
        )
    }
    ManagedSlotRegistry.shared.normalizeSlots(screen: screen)
    ...
}
```

> `windowIndex(for:inSlot:)` is a small lookup on `ManagedSlotRegistry` that returns the index of a window within a given slot. If it doesn't exist yet, add it:
>
> ```swift
> func windowIndex(for key: ManagedWindow, inSlot slotIndex: Int) -> Int? {
>     queue.sync {
>         guard slotIndex >= 0, slotIndex < slots.count else { return nil }
>         return slots[slotIndex].windows.firstIndex(of: key)
>     }
> }
> ```

---

## Key Technical Notes

- **Left/Right create new slots** instead of moving existing ones. This means a window is always extracted individually — if the source slot had multiple windows, the remaining windows stay in the source slot and their heights are equalized.
- **New slot width = source slot width**, not the target slot width. This preserves the user's sizing intent from the original position.
- **No max-window-per-slot limit on bottom/top zones.** The `< 2` guard is removed. Any slot can receive additional windows.
- **Center zone swaps individual windows, not slots.** The hit-test walks the window list in the target slot to find which window the cursor is over. Heights are swapped because the entire `ManagedWindow` structs (which include `height`) are exchanged between positions.
- **`equalizeHeights` is a shared private helper** to avoid duplicated height math across mutations. It is called on the source slot (when windows remain) and on the target slot (after insert).
- **Old methods removed:** `moveSlot(containing:before/after:)`, `swapSlots(_:_:)`, `swapWindowsInSlot(_:_:_:)` — replaced by `insertSlotBefore`, `insertSlotAfter`, `swapWindows`.

---

## Verification

1. **Left insert**: Snap A | B. Drag B over A's left zone. Overlay appears in gap left of A. Release → new slot with B is created before A. Layout: B | A. B has source slot width, height 100 %.
2. **Right insert**: Snap A | B. Drag A over B's right zone. Release → new slot with A is created after B. Layout: B | A.
3. **Top split**: Snap A | B. Drag B over A's top zone. Overlay shows upper portion of A's slot. Release → A's slot now has [B, A] top-to-bottom. Heights equalized.
4. **Bottom split**: Same as top but B is appended. Slot has [A, B] top-to-bottom.
5. **Center swap (across slots)**: Snap A | B. Drag A over B's center. Overlay covers B (not the whole slot). Release → A and B swap positions and heights.
6. **Center swap (within slot)**: Slot has [A, B] vertically. Drag A over B's center. Overlay covers B. Release → slot becomes [B, A]. Heights swapped — B gets A's old height and vice versa.
7. **Center swap (multi-window slots)**: Slot 1 has [A, B], Slot 2 has [C]. Drag B over C's center. Release → Slot 1 has [A, C], Slot 2 has [B]. Heights of B and C are swapped.
8. **Multi-window source**: Slot has [A, B] vertically. Drag A over another slot's left zone. A is extracted, B remains in source slot with full height. New slot with A is created.
9. **Source slot cleanup**: If the extracted window was the only window in its slot, the source slot is removed entirely.
10. **Resize after any operation** (regression): reflow works correctly from new slot arrangement.
