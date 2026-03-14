# Plan: 11_scrolling_center_resize — Resizable Center Slot in Scrolling Root

## Checklist

- [x] Add `centerWidthFraction: CGFloat?` to `ScrollingRootSlot`
- [x] Update `ScrollingPositionService.recomputeSizes` to use stored fraction (default 0.8)
- [x] Update `ScrollingLayoutService.applyLayout` to use stored fraction
- [x] Create `ScrollingResizeService` — clamps and stores new center fraction
- [x] Wire `ResizeObserver` to detect scrolling center resize and call `ScrollingResizeService`
- [x] Call `PostResizeValidator.checkAndFixRefusals` after reapplication

---

## Context / Problem

Currently the center slot of a scrolling root is always 80% of screen width (hardcoded in both `ScrollingPositionService` and `ScrollingLayoutService`). The user cannot manually resize it.

**Goal:** When the user drags the edge of the center window to resize it, the app accepts the new width, stores it as a fraction, re-centres the center slot horizontally, and repositions the left/right slots accordingly.

Constraints:
- **Max center width**: 90% of screen width
- **Min center width**: `screenWidth − leftMinPeek − rightMinPeek`
  - `leftMinPeek = 50` if a left slot exists, else `0`
  - `rightMinPeek = 50` if a right slot exists, else `0`
  - (Ensures side zones always have at least 50 px of visible slot boundary)

---

## Behaviour spec

The stored fraction persists across scrolls (left/right) and window add/remove so the center stays at the user's chosen width until they resize again or leave the scrolling root entirely.

Center position is always `origin.x + leftSlotWidth`, where `leftSlotWidth` is the side slot boundary width. With a larger center, side slots shrink; both sides split the remaining width evenly (existing behaviour).

Side windows are still sized to `centerWidth` so they peek behind center — this is unchanged.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Model/ScrollingRootSlot.swift` | Modify — add `centerWidthFraction: CGFloat?` |
| `UnnamedWindowManager/Services/ScrollingPositionService.swift` | Modify — use stored fraction; expose min/max clamp helper |
| `UnnamedWindowManager/System/ScrollingLayoutService.swift` | Modify — use stored fraction instead of hardcoded 0.8 |
| `UnnamedWindowManager/Services/ScrollingResizeService.swift` | **New file** — accepts AX-reported center width, clamps, stores fraction |
| `UnnamedWindowManager/Observation/ResizeObserver.swift` | Modify — detect scrolling resize of center window, call `ScrollingResizeService` |

---

## Implementation Steps

### 1. Add `centerWidthFraction` to `ScrollingRootSlot`

Add an optional field defaulting to `nil` (nil means "use default 0.8"):

```swift
struct ScrollingRootSlot {
    var id: UUID
    var width: CGFloat
    var height: CGFloat
    var centerWidthFraction: CGFloat?   // nil = default 0.8
    var left: Slot?
    var center: Slot
    var right: Slot?
}
```

All existing call sites that create a `ScrollingRootSlot` omit the new field, relying on Swift's default memberwise init ordering — but since the field has no default value in a struct, all sites must be updated to pass `centerWidthFraction: nil` explicitly, or the field must be given a default. **Use `= nil` as the default** to avoid touching every construction site.

### 2. Update `ScrollingPositionService`

Replace the `private let centerFraction: CGFloat = 0.8` constant with a per-call parameter drawn from the root:

```swift
func recomputeSizes(_ root: inout ScrollingRootSlot, width: CGFloat, height: CGFloat) {
    root.width  = width
    root.height = height
    let fraction    = root.centerWidthFraction ?? 0.8
    let centerWidth = (width * fraction).rounded()
    let remaining   = width - centerWidth
    let bothSides   = root.left != nil && root.right != nil
    let sideWidth   = (bothSides ? remaining / 2 : remaining).rounded()
    // rest unchanged …
}
```

Also add a static helper that computes the clamped fraction — used by `ScrollingResizeService`:

```swift
static func clampedCenterFraction(
    proposedWidth: CGFloat,
    screenWidth: CGFloat,
    hasLeft: Bool,
    hasRight: Bool
) -> CGFloat {
    let leftPeek  = hasLeft  ? CGFloat(50) : 0
    let rightPeek = hasRight ? CGFloat(50) : 0
    let minWidth  = screenWidth - leftPeek - rightPeek
    let maxWidth  = (screenWidth * 0.9).rounded()
    let clamped   = min(maxWidth, max(minWidth, proposedWidth))
    return clamped / screenWidth
}
```

### 3. Update `ScrollingLayoutService`

Replace the hardcoded `0.8` with the stored fraction:

```swift
func applyLayout(root: ScrollingRootSlot, origin: CGPoint, …) {
    let fraction    = root.centerWidthFraction ?? 0.8
    let centerWidth = (root.width * fraction).rounded()
    // rest unchanged …
}
```

### 4. Create `ScrollingResizeService`

New file that computes the new fraction from the AX-reported window size, applies the clamp, and persists it:

```swift
// Handles user-initiated resizes of the scrolling center slot.
struct ScrollingResizeService {

    func applyResize(centerKey: WindowSlot, actualWidth: CGFloat, screen: NSScreen) {
        let og = Config.outerGaps
        let screenWidth = screen.visibleFrame.width - og.left! - og.right!

        ScrollingTileService.shared.updateCenterFraction(
            for: centerKey,
            proposedWidth: actualWidth,
            screenWidth: screenWidth
        )
    }
}
```

Add `updateCenterFraction` to `ScrollingTileService`:

```swift
func updateCenterFraction(for key: WindowSlot, proposedWidth: CGFloat, screenWidth: CGFloat) {
    store.queue.sync(flags: .barrier) {
        guard let id = visibleScrollingRootID(),
              case .scrolling(var root) = store.roots[id] else { return }

        // Only respond when key is the center window.
        guard isCenterWindow(key, in: root) else { return }

        let fraction = ScrollingPositionService.clampedCenterFraction(
            proposedWidth: proposedWidth,
            screenWidth: screenWidth,
            hasLeft:  root.left  != nil,
            hasRight: root.right != nil
        )
        root.centerWidthFraction = fraction
        let og = Config.outerGaps
        let w  = screenWidth
        let h  = screen.visibleFrame.height - og.top! - og.bottom!
        position.recomputeSizes(&root, width: w, height: h)
        store.roots[id] = .scrolling(root)
    }
}
```

Add a private `isCenterWindow` helper to `ScrollingTileService`:

```swift
private func isCenterWindow(_ key: WindowSlot, in root: ScrollingRootSlot) -> Bool {
    switch root.center {
    case .window(let w):   return w.windowHash == key.windowHash
    case .stacking(let s): return s.children.contains { $0.windowHash == key.windowHash }
    default:               return false
    }
}
```

Note: `updateCenterFraction` needs `screen` passed in. Pass it from the call site in `ResizeObserver`.

### 5. Wire `ResizeObserver`

In `scheduleReapplyWhenMouseUp`, the scrolling path currently always snaps back without accepting the resize. Change it so that a **resize** (not move) of the center window calls `ScrollingResizeService`:

```swift
if isScrolling {
    self.reapplying.insert(key)
    if let screen = NSScreen.main {
        if isResize, let axElement = self.elements[key],
           let actualSize = readSize(of: axElement),
           ScrollingTileService.shared.isCenterWindow(key) {
            ScrollingResizeService().applyResize(
                centerKey: key, actualWidth: actualSize.width, screen: screen)
        }
        LayoutService.shared.applyLayout(screen: screen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let windows = ScrollingTileService.shared.leavesInVisibleScrollingRoot()
                .compactMap { if case .window(let w) = $0 { return w } else { return nil } }
            PostResizeValidator.checkAndFixRefusals(windows: Set(windows), screen: screen)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.reapplying.remove(key)
    }
    return
}
```

Make `isCenterWindow(_ key: WindowSlot)` public in `ScrollingTileService` (no root argument — reads from store internally).

---

## Key Technical Notes

- `ScrollingLayoutService.applyLayout` and `ScrollingPositionService.recomputeSizes` both inline the 0.8 fraction — both must be updated or they'll diverge.
- `clampedCenterFraction` should be `static` on `ScrollingPositionService` (not an instance method) so `ScrollingResizeService` and `ScrollingTileService` can call it without constructing an instance.
- `isCenterWindow` needs two versions: one taking a root (private, for `updateCenterFraction`) and one reading from the store (public, for `ResizeObserver`).
- Side window widths equal `centerWidth` (they peek behind center) — this doesn't change. A wider center → side windows also become wider, which is correct.
- The 0.3 s delay for `PostResizeValidator` allows `LayoutService.applyLayout` to complete and windows to settle.
- When the scrolling root has only a center (no sides), the user can resize freely between 10% and 90% — the formula reduces to `min = screenWidth - 0 - 0` which is unachievable, so the effective minimum is just the max clamp from the system (AX minimum window size).
- `readSize(of:)` is a free function already used in the tiling resize path — reuse it directly.

---

## Verification

1. Enter scrolling mode with two windows → drag the right edge of the center window to make it wider → center widens, left slot shrinks, center stays horizontally centred relative to its new position.
2. Drag center window edge past 90% of screen width → it snaps back to 90%.
3. With both left and right slots present, drag center edge so side slots would be < 50 px → center snaps to the minimum.
4. After resizing, scroll left/right → center retains the custom width.
5. Add another window to the scrolling root after resizing → center retains the custom width.
6. Exit scrolling mode and re-enter → fraction resets to default 0.8 (new root is created fresh).
7. Move the center window (not resize) → snaps back to its slot position with no fraction change.
