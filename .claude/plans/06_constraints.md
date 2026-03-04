# Plan: 06_constraints — Single-Window Size Limits

## Checklist

- [x] Add `maxWidthFraction` and `maxHeightFraction` constants to `Config.swift`
- [x] Add `clampSize(_:screen:)` helper to `SnapLayout.swift`
- [x] Apply clamp in `WindowSnapper.snap()` before registering width/height
- [x] Apply clamp in `SnapRegistry.setSize(width:height:for:)` before storing (enforces limits on user resize)

---

## Context

After 05_swap, snapped windows keep their original width and height as entered at snap time. There are no upper bounds, so a maximised window snapped into the layout will stay at full-screen width or height, breaking the layout.

This plan introduces **per-window size limits** that are enforced at two points:

1. **At snap time** — the captured width/height is clamped before it is stored in `SnapEntry`.
2. **At user-resize** — when the user resizes a snapped window and `ResizeObserver` calls `setSize`, the incoming dimensions are clamped before storage so the limit persists.

Limits (relative to `NSScreen.main?.visibleFrame`):

| Dimension | Limit | Rationale |
|---|---|---|
| **Width** | ≤ 80 % of visible screen width | Prevents a single window from dominating a multi-window layout |
| **Height** | ≤ 100 % of visible screen height minus top/bottom gaps | A window should never overflow the visible area vertically |

The height limit is `visible.height − 2 × Config.gap`, which is already the value used for `snapHeight` in `snap()`. Making it an explicit clamp means user resizes cannot exceed it either.

---

## Files to modify

| File | Action |
|---|---|
| `UnnamedWindowManager/Config.swift` | Add `maxWidthFraction` and `maxHeightFraction` constants |
| `UnnamedWindowManager/Snapping/SnapLayout.swift` | Add `clampSize(_:screen:)` extension helper |
| `UnnamedWindowManager/Snapping/WindowSnapper.swift` | Apply `clampSize` to `originalWidth` / `snapHeight` before `register` |
| `UnnamedWindowManager/Model/SnapRegistry.swift` | Apply `clampSize` inside `setSize(width:height:for:)` |

---

## Implementation Steps

### 1. `Config.swift` — new constants

```swift
/// Maximum width of a snapped window as a fraction of the visible screen width.
static let maxWidthFraction: CGFloat = 0.80
/// Maximum height of a snapped window as a fraction of the visible screen height
/// (before gap subtraction; the actual pixel cap is applied via clampSize).
static let maxHeightFraction: CGFloat = 1.0
```

`maxHeightFraction` is kept as `1.0` so the cap is always expressed in the same formula as the width cap. The effective pixel limit will be `visible.height * 1.0 − 2 × Config.gap`.

---

### 2. `SnapLayout.swift` — `clampSize` helper

Add to the `WindowSnapper` extension:

```swift
/// Returns `size` with width and height clamped to the per-screen maximums.
static func clampSize(_ size: CGSize, screen: NSScreen) -> CGSize {
    let visible = screen.visibleFrame
    let maxW = visible.width  * Config.maxWidthFraction
    let maxH = visible.height * Config.maxHeightFraction - Config.gap * 2
    return CGSize(
        width:  min(size.width,  maxW),
        height: min(size.height, maxH)
    )
}
```

Placing it in `SnapLayout.swift` keeps all layout math in one file and makes it reusable by both `WindowSnapper` and `SnapRegistry`.

---

### 3. `WindowSnapper.snap()` — clamp at snap time

Replace the current width/height capture:

```swift
// Before
let snapHeight = visible.height - Config.gap * 2
let originalWidth = readSize(of: axWindow)?.width ?? visible.width * Config.fallbackWidthFraction

// After
let rawSize = CGSize(
    width:  readSize(of: axWindow)?.width ?? visible.width * Config.fallbackWidthFraction,
    height: visible.height - Config.gap * 2
)
guard let screen = NSScreen.main else { return }
let clamped = WindowSnapper.clampSize(rawSize, screen: screen)

SnapRegistry.shared.register(key, slot: slot, width: clamped.width, height: clamped.height)
```

The `visible` binding already exists in `snap()` — `screen` can be obtained from the same `NSScreen.main` call.

---

### 4. `SnapRegistry.setSize` — clamp on user resize

`ResizeObserver+Reapply.swift` calls `SnapRegistry.shared.setSize(width:height:for:)` when a user resizes a snapped window before reapplying. Add clamping at the entry point of `setSize`:

```swift
func setSize(width: CGFloat, height: CGFloat, for key: SnapKey) {
    guard let screen = NSScreen.main else { return }
    let clamped = WindowSnapper.clampSize(CGSize(width: width, height: height), screen: screen)
    queue.async(flags: .barrier) {
        self.store[key]?.width  = clamped.width
        self.store[key]?.height = clamped.height
    }
}
```

This ensures that even if the user manually drags a snapped window larger than the limit, the stored (and subsequently reapplied) dimensions never exceed the caps.

---

## Key Technical Notes

- **`clampSize` is screen-aware**: both caps are computed from `visible.visibleFrame`, so they automatically adapt if the user has a different monitor or changes the Dock size.
- **Height cap formula**: `visible.height − 2 × Config.gap` matches the initial `snapHeight` already set in `snap()`, so the clamp is a no-op at snap time for height. Its value is in enforcing the limit on subsequent user resizes.
- **Width clamp does not reflow other windows**: clamping only changes the stored width of the affected window. A `reapplyAll()` call (already triggered by `ResizeObserver+Reapply`) will reflow the layout using the clamped width.
- **`NSScreen.main` inside `setSize`**: called on the main-thread-adjacent path from `ResizeObserver`, so `NSScreen.main` is safe to query here.
- **No UI change required**: limits are enforced silently; the window simply snaps back to the clamped size if the user tries to exceed it.

---

## Verification

1. Open a window that fills the full screen width. Snap it → stored width is capped at 80 % of the visible screen width; the window repositions to that capped width.
2. Open a window with a very tall height. Snap it → stored height is capped at `visible.height − 2 × gap`; the window does not overflow the screen.
3. After snapping, manually resize the window wider than 80 % → it snaps back to the 80 % cap.
4. After snapping, manually resize the window taller than the cap → it snaps back to `visible.height − 2 × gap`.
5. Snap two windows. Resize one within the allowed limit → `reapplyAll()` reflows correctly from the new (within-cap) width.
6. Resize one window beyond the width cap → it snaps back to 80 %; the other window's position is unaffected.
