# Plan: 08_vertical_split — Vertical Split Drop Zone

## Checklist

- [x] Add `row: Int = 0` to `SnapEntry` and `.bottom` to `DropZone` in `SnapTypes.swift`
- [x] Add `dropZoneBottomFraction` to `Config.swift`
- [x] Update `allEntries` sort and `nextSlot` in `SnapRegistry.swift`
- [x] Add `splitVertical(_:below:screen:)` to `SnapRegistry+SlotMutations.swift`
- [x] Update `findDropTarget`, `applyPosition`, add `bottomSplitOverlayFrame` in `SnapLayout.swift`
- [x] Handle `.bottom` zone in `ResizeObserver+SwapOverlay.swift`
- [x] Dispatch `.bottom` drop action in `ResizeObserver+Reapply.swift`

---

## Context

After 07_drop_zones, each snapped window has three horizontal drop zones (left 10 %, center 80 %, right 10 %). All snapped windows occupy a single horizontal row.

This plan adds a **bottom vertical split zone** at the center of each window. When the user drags a snapped window and releases over the bottom zone of a target window, the two windows are stacked vertically at the same horizontal column, each taking 50 % of the visible screen height.

---

## Model change: `row` in `SnapEntry`

All existing windows are in row 0 (the single horizontal row). A vertically split partner is placed in row 1 — same slot, same X offset, positioned immediately below its row-0 sibling.

`SnapEntry` gains `var row: Int = 0`. Swift's synthesized memberwise initializer includes the default, so all existing construction sites (`register`, `swapSlots`, etc.) remain valid without changes.

---

## Drop zone table

| Zone | Horizontal extent | Vertical extent | Overlay | Drop action |
|---|---|---|---|---|
| **Left** | leftmost 10 % of target width | full height | gap left of target | insert before target |
| **Center** | middle 80 % of target width | upper 80 % of height | over target window | swap |
| **Right** | rightmost 10 % of target width | full height | gap right of target | insert after target |
| **Bottom** | middle 80 % of target width | bottom 20 % of height | lower half at target's column | vertical split |

The bottom zone shares the same horizontal extent as the center zone. The vertical check only runs after left/right have been ruled out.

---

## Files to modify

| File | Action |
|---|---|
| `UnnamedWindowManager/Model/SnapTypes.swift` | Add `row: Int = 0` to `SnapEntry`; add `.bottom` to `DropZone` |
| `UnnamedWindowManager/Config.swift` | Add `dropZoneBottomFraction: CGFloat = 0.20` |
| `UnnamedWindowManager/Model/SnapRegistry.swift` | Sort `allEntries` by (slot, row); filter `nextSlot` to row-0 only |
| `UnnamedWindowManager/Model/SnapRegistry+SlotMutations.swift` | Add `splitVertical(_:below:screen:)` |
| `UnnamedWindowManager/Snapping/SnapLayout.swift` | Update `findDropTarget`; update `applyPosition`; add `bottomSplitOverlayFrame` |
| `UnnamedWindowManager/Observation/ResizeObserver+SwapOverlay.swift` | Handle `.bottom` case in overlay switch |
| `UnnamedWindowManager/Observation/ResizeObserver+Reapply.swift` | Dispatch `.bottom` to `splitVertical` |

---

## Implementation Steps

### 1. `SnapTypes.swift` — extend model

```swift
struct SnapEntry {
    var slot:   Int
    var width:  CGFloat
    var height: CGFloat
    var row:    Int = 0   // 0 = primary row; 1 = stacked below slot partner
}

enum DropZone {
    case left    // insert dragged window before target
    case center  // swap dragged and target
    case right   // insert dragged window after target
    case bottom  // vertical split — stack dragged window below target
}
```

---

### 2. `Config.swift` — new constant

```swift
/// Fraction of a window's height (measured from the bottom) that activates the vertical-split zone.
static let dropZoneBottomFraction: CGFloat = 0.20
```

---

### 3. `SnapRegistry.swift` — sort and slot accounting

**`allEntries`** — sort by (slot, row) so row-0 partners always appear before row-1 during iteration:

```swift
func allEntries() -> [(key: SnapKey, entry: SnapEntry)] {
    queue.sync {
        store.map { (key: $0.key, entry: $0.value) }
             .sorted {
                 $0.entry.slot != $1.entry.slot
                     ? $0.entry.slot < $1.entry.slot
                     : $0.entry.row  < $1.entry.row
             }
    }
}
```

**`nextSlot`** — row-1 windows share a slot with their row-0 partner and must not inflate the slot counter:

```swift
func nextSlot() -> Int {
    queue.sync {
        (store.values.filter { $0.row == 0 }.map(\.slot).max() ?? -1) + 1
    }
}
```

---

### 4. `SnapRegistry+SlotMutations.swift` — `splitVertical`

```swift
/// Stacks `draggedKey` below `targetKey` in the same horizontal column.
/// Both windows are resized to half the visible screen height.
func splitVertical(_ draggedKey: SnapKey, below targetKey: SnapKey, screen: NSScreen) {
    let visible = screen.visibleFrame
    // Three gaps consumed vertically: top edge, middle between windows, bottom edge.
    let halfH = (visible.height - Config.gap * 3) / 2

    queue.sync(flags: .barrier) {
        guard let targetEntry = self.store[targetKey] else { return }
        self.store[targetKey]?.height = halfH
        self.store[draggedKey]?.slot   = targetEntry.slot
        self.store[draggedKey]?.row    = 1
        self.store[draggedKey]?.height = halfH
        self.store[draggedKey]?.width  = targetEntry.width
    }
}
```

The dragged window's width is set to match the target so both halves form a clean vertical column.

---

### 5. `SnapLayout.swift` — hit-test, position, overlay

#### 5a. `findDropTarget` — add bottom zone check

Replace the existing implementation:

```swift
static func findDropTarget(for key: SnapKey) -> DropTarget? {
    guard let screen = NSScreen.main else { return nil }

    let cursorX       = NSEvent.mouseLocation.x
    let cursorY       = NSEvent.mouseLocation.y   // AppKit coords (bottom-left origin)
    let primaryHeight = NSScreen.screens[0].frame.height
    let entries       = SnapRegistry.shared.allEntries()

    for item in entries where item.key != key {
        guard let range = xRange(for: item.key, entries: entries, screen: screen) else { continue }
        guard range.contains(cursorX) else { continue }

        let windowWidth = range.upperBound - range.lowerBound
        let leftEnd     = range.lowerBound + windowWidth * Config.dropZoneFraction
        let rightStart  = range.lowerBound + windowWidth * (1 - Config.dropZoneFraction)

        // Horizontal-only zones — checked first.
        if cursorX < leftEnd  { return DropTarget(key: item.key, zone: .left)  }
        if cursorX > rightStart { return DropTarget(key: item.key, zone: .right) }

        // Cursor is in the horizontal center — check vertical zone.
        // AppKit Y of the window's bottom edge (Y increases upward in AppKit).
        let axY          = primaryHeight - screen.visibleFrame.maxY + Config.gap
        let appKitBottom = primaryHeight - axY - item.entry.height
        let bottomZoneTop = appKitBottom + item.entry.height * Config.dropZoneBottomFraction

        if cursorY <= bottomZoneTop {
            return DropTarget(key: item.key, zone: .bottom)
        }

        return DropTarget(key: item.key, zone: .center)
    }
    return nil
}
```

`cursorY <= bottomZoneTop` selects the bottom `dropZoneBottomFraction` of the window: because AppKit Y increases upward, the lowest AppKit Y values correspond to the visual bottom of the window.

#### 5b. `applyPosition` — handle row 1

```swift
static func applyPosition(
    to window: AXUIElement,
    key: SnapKey,
    entries: [(key: SnapKey, entry: SnapEntry)]? = nil
) {
    guard let screen = NSScreen.main else { return }
    let visible       = screen.visibleFrame
    let primaryHeight = NSScreen.screens[0].frame.height

    let allEntries = entries ?? SnapRegistry.shared.allEntries()
    guard let myEntry = allEntries.first(where: { $0.key == key })?.entry else { return }

    // Accumulate only row-0 widths: row-1 windows share a slot with their partner
    // and must not double-count the column width.
    var xOffset = visible.minX + Config.gap
    for item in allEntries {
        if item.entry.slot == myEntry.slot { break }
        if item.entry.row == 0 { xOffset += item.entry.width + Config.gap }
    }

    let axY: CGFloat
    if myEntry.row == 0 {
        axY = primaryHeight - visible.maxY + Config.gap
    } else {
        // Row 1: position below the row-0 partner at the same slot.
        if let partner = allEntries.first(where: {
            $0.entry.slot == myEntry.slot && $0.entry.row == 0
        }) {
            let partnerAxY = primaryHeight - visible.maxY + Config.gap
            axY = partnerAxY + partner.entry.height + Config.gap
        } else {
            axY = primaryHeight - visible.maxY + Config.gap  // fallback if partner missing
        }
    }

    var origin = CGPoint(x: xOffset, y: axY)
    var size   = CGSize(width: myEntry.width, height: myEntry.height)

    if let posVal = AXValueCreate(.cgPoint, &origin) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
    }
    if let sizeVal = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
    }
}
```

#### 5c. `bottomSplitOverlayFrame` — new helper

```swift
/// Frame of the lower-half split rectangle (where dragged window will land), in AppKit screen coords.
static func bottomSplitOverlayFrame(for targetKey: SnapKey, screen: NSScreen) -> CGRect? {
    let entries = SnapRegistry.shared.allEntries()
    guard let range = xRange(for: targetKey, entries: entries, screen: screen),
          let entry = entries.first(where: { $0.key == targetKey })?.entry else { return nil }

    let visible = screen.visibleFrame
    let halfH   = (visible.height - Config.gap * 3) / 2

    return CGRect(
        x:      range.lowerBound,
        y:      visible.minY + Config.gap,   // AppKit Y: Dock-adjusted bottom + gap
        width:  entry.width,
        height: halfH
    )
}
```

---

### 6. `ResizeObserver+SwapOverlay.swift` — `.bottom` overlay

Add the `.bottom` case to the zone switch in `updateSwapOverlay`:

```swift
case .bottom:
    frame = WindowSnapper.bottomSplitOverlayFrame(for: target.key, screen: screen)
```

---

### 7. `ResizeObserver+Reapply.swift` — dispatch `.bottom`

Add the `.bottom` case to the zone switch in `scheduleReapplyWhenMouseUp`:

```swift
case .bottom:
    guard let screen = NSScreen.main else { return }
    SnapRegistry.shared.splitVertical(key, below: target.key, screen: screen)
```

The existing `reapplyAll()` call that follows the switch handles repositioning both windows.

---

## Key Technical Notes

- **`row` field default 0** — Swift's synthesized memberwise initializer includes default values, so all existing `SnapEntry(slot:width:height:)` call sites compile without changes.
- **`xOffset` accumulation filters `row == 0`** — two windows at the same slot must contribute only one column width. Without the filter, a slot with a row-0 and row-1 window would add the width twice for any higher-slot window.
- **Half-height formula** — `(visible.height − gap × 3) / 2` allocates three gaps (top edge, middle, bottom edge) so the two halves exactly fill the visible screen area.
- **Bottom zone Y check** — `cursorY <= bottomZoneTop` uses AppKit Y (increasing upward). The visual bottom of a window has the *smallest* AppKit Y value, so the condition selects the lower 20 % correctly.
- **Overlay frame** — `visible.minY + Config.gap` is the AppKit Y origin of the lower half. `visible.minY` is the Dock-adjusted bottom; adding `Config.gap` matches the standard screen-edge margin.
- **`nextSlot` filters `row == 0`** — row-1 windows share a slot with their partner and must not increment the horizontal column counter for newly snapped windows.
- **`allEntries` sort by (slot, row)** — guarantees row-0 partners precede row-1 during `applyPosition` and slot-reindexing operations.
- **`splitVertical` sets dragged width = target width** — enforces a clean vertical column; the dragged window's previous width is intentionally overwritten.
- **`reapplyAll` after split** — the existing dispatch in `Reapply` already calls `reapplyAll()` after any zone-switch action, which repositions both windows correctly.

---

## Verification

1. **Basic split**: Snap A and B side by side. Drag B over A's bottom zone (bottom 20 %, center 80 % horizontally). Overlay appears as a rectangle in the lower half of A's column. Release → A occupies the upper half, B the lower half; both are 50 % of screen height.
2. **Overlay appears only in bottom zone**: Hover B over A's center zone (upper 80 %) → overlay covers A entirely (swap). Move cursor to bottom 20 % → overlay switches to the lower-half rectangle.
3. **Left/right zones unaffected**: Hover over A's left 10 % → gap overlay appears left of A. Hover over right 10 % → gap overlay appears right of A. Bottom zone does not activate in these regions.
4. **Third window unaffected**: After splitting A and B vertically, snap C to the right. C should appear at a new horizontal slot at full height; A and B remain stacked.
5. **Snap-back after drag**: After the split, drag B away and drop on empty space → B restores to the lower half of A's column (slot unchanged, row 1).
6. **Resize after split**: Resize A horizontally → `reapplyAll` repositions B to match A's new width (same slot, row 1).
7. **`nextSlot` correctness**: After A/B split, snap D → D lands in a new slot to the right of C, not at A/B's shared slot.
