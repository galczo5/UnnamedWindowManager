# Plan: 14_horizontal_scroll — Scroll Left / Right via Menu

## Checklist

- [x] Create `CurrentOffset.swift` — singleton holding the scroll offset value
- [x] Add "Scroll Left" and "Scroll Right" menu items in `UnnamedWindowManagerApp.swift`
- [x] Apply offset in `applyPosition` (SnapLayout.swift)
- [x] Apply offset in `xRange` (SnapLayout.swift) — affects drop-zone hit-testing and gap overlays
- [x] Apply offset in `applyVisibility` (WindowVisibilityManager.swift) — off-screen detection must account for scroll position
- [x] Apply offset in Debug button xOffset display (UnnamedWindowManagerApp.swift)

---

## Problem

When many windows are snapped side-by-side the layout can be wider than the screen. There is no way to bring off-screen slots into view without unsapping and re-snapping. The feature adds a persistent horizontal scroll offset so the user can pan the layout left or right 100 pt at a time.

---

## Design

### `CurrentOffset`

```swift
final class CurrentOffset {
    static let shared = CurrentOffset()
    private init() {}

    private(set) var value: Int = 0

    func scrollRight() {
        value += 100
    }

    func scrollLeft() {
        value = max(0, value - 100)
    }
}
```

- `value` is a non-negative integer (points). It cannot go below 0, so the layout cannot shift right of its natural origin.
- Stored as `Int`; cast to `CGFloat` at each use site.

### Semantics

| Action | Effect on `value` | Effect on windows |
|--------|-------------------|-------------------|
| Scroll Right | `+= 100` | Windows shift left — right-side slots come into view |
| Scroll Left  | `-= 100` (min 0) | Windows shift right — returns toward natural position |

### How position X is affected

Every place that computes the starting `xOffset` for slot layout currently does:

```swift
var xOffset = visible.minX + Config.gap
```

It becomes:

```swift
var xOffset = visible.minX + Config.gap - CGFloat(CurrentOffset.shared.value)
```

This is the only arithmetic change needed — all per-slot accumulation remains identical.

---

## Files to modify

| File | Action |
|------|--------|
| `CurrentOffset.swift` | **New file** — scroll offset singleton |
| `UnnamedWindowManagerApp.swift` | Add "Scroll Left" / "Scroll Right" buttons; update Debug xOffset display |
| `SnapLayout.swift` | Subtract offset in `applyPosition` and `xRange` |
| `WindowVisibilityManager.swift` | Subtract offset in `applyVisibility` xOffset accumulation |

---

## Implementation

### 1. `CurrentOffset.swift` — new file

```swift
//
//  CurrentOffset.swift
//  UnnamedWindowManager
//

import CoreGraphics

final class CurrentOffset {
    static let shared = CurrentOffset()
    private init() {}

    private(set) var value: Int = 0

    func scrollRight() {
        value += 100
    }

    func scrollLeft() {
        value = max(0, value - 100)
    }
}
```

Place in the `Model` group (alongside `ManagedTypes.swift`).

---

### 2. `UnnamedWindowManagerApp.swift` — menu items

Add two buttons between the `Divider()` and the `Debug` button:

```swift
Divider()
Button("Scroll Left")  { CurrentOffset.shared.scrollLeft();  WindowSnapper.reapplyAll() }
Button("Scroll Right") { CurrentOffset.shared.scrollRight(); WindowSnapper.reapplyAll() }
Button("Debug") { ... }
```

Also update the Debug display so `xOffset` matches what windows actually use:

```swift
var xOffset = (visible?.minX ?? 0) + Config.gap - CGFloat(CurrentOffset.shared.value)
```

---

### 3. `SnapLayout.swift` — `applyPosition` and `xRange`

**`applyPosition`** (line 176):

```swift
// Before:
var xOffset = visible.minX + Config.gap
// After:
var xOffset = visible.minX + Config.gap - CGFloat(CurrentOffset.shared.value)
```

**`xRange`** (line 216):

```swift
// Before:
var xOffset = visible.minX + Config.gap
// After:
var xOffset = visible.minX + Config.gap - CGFloat(CurrentOffset.shared.value)
```

`xRange` is used by `findDropTarget`, `leftGapFrame`, `rightGapFrame`, `bottomSplitOverlayFrame`, and `topSplitOverlayFrame` — all hit-test/overlay helpers automatically pick up the offset via this single change.

---

### 4. `WindowVisibilityManager.swift` — `applyVisibility`

```swift
// Before:
var xOffset = visible.minX + Config.gap
// After:
var xOffset = visible.minX + Config.gap - CGFloat(CurrentOffset.shared.value)
```

With a positive scroll offset, `xOffset` can be negative (slots pushed left of `visible.minX`). The existing `isOffScreen = xOffset >= visible.maxX` check still works correctly for right-side overflow. Left-side slots (xOffset + slot.width <= visible.minX) are also effectively off-screen; the auto-minimize logic from plan 13 already handles right-side minimization and this plan does not extend it to the left side — that can be addressed separately if needed.

---

## Key technical notes

- **One value, four call sites**: All layout math flows through `xOffset = visible.minX + Config.gap`. Subtracting the offset at that single starting point is sufficient; no further changes to accumulation or per-slot arithmetic.
- **No persistence**: `CurrentOffset` resets to 0 on app restart. Persisting it across launches is out of scope.
- **Negative xOffset starting point**: When `CurrentOffset.shared.value > 0`, windows in early slots may be placed left of `visible.minX`. They remain unminimized but partially or fully off-screen to the left. This is intentional; the user controls this via Scroll Left to return.
- **`reapplyAll` integration**: Both scroll actions call `reapplyAll()` directly, which repositions all tracked windows and runs `applyVisibility`. No other call sites need updating.
- **`xRange` and drag-drop**: Because `xRange` is used for drop-zone detection, drag-drop hit-testing will correctly track slots at their scrolled positions.

---

## Verification

1. **Scroll Right shifts windows left**: Snap two wide windows. Click Scroll Right. Both windows shift 100 pt to the left.
2. **Scroll Left reverses**: After scrolling right, click Scroll Left. Windows return 100 pt to the right.
3. **Floor at 0**: At offset 0, clicking Scroll Left is a no-op (no negative shift).
4. **Auto-minimize still works**: With scroll, slots at `xOffset >= visible.maxX` are still auto-minimized by `applyVisibility`.
5. **Drop-zone hit-testing tracks scroll**: Drag a snapped window. Drop zones appear at the scrolled positions of other slots, not at their natural positions.
6. **Debug output shows scrolled xOffset**: The Debug alert shows xOffset values that match the actual window positions on screen.
