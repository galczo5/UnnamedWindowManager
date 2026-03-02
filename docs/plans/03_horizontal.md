# Plan: 03_horizontal — Right-Side Horizontal Tiling

## Checklist

- [x] Remove `SnapSide` enum; replace with slot-based registry (`[SnapKey: Int]`)
- [x] Update `SnapRegistry.swift` — store slot index, add `nextSlot()` helper
- [x] Update `WindowSnapper.swift` — remove `.left`, tile windows right-to-left by slot
- [x] Update `UnnamedWindowManagerApp.swift` — remove "Snap Left" button

---

## Context

After 02_resize, windows snap left or right and hold their position. This plan removes the left snap and introduces **horizontal tiling on the right side**: each new "Snap Right" call places the incoming window immediately to the left of the previously snapped window, all sharing the same width and gap. The result is a right-anchored horizontal stack that grows leftward.

---

## Files to modify

| File | Action |
|---|---|
| `UnnamedWindowManager/SnapRegistry.swift` | Modify — replace `SnapSide` with slot `Int`, add `nextSlot()` |
| `UnnamedWindowManager/WindowSnapper.swift` | Modify — slot-based `applyFrame`, drop `.left` |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — remove "Snap Left" button |

---

## Implementation Steps

### 1. Slot-based identity in `SnapRegistry`

Replace `SnapSide` with a plain `Int` slot index:

```
slot 0 → rightmost window (anchored to right edge)
slot 1 → immediately to the left of slot 0
slot 2 → immediately to the left of slot 1
…
```

Slots are monotonically assigned (`max(existing) + 1`), so unsnapping a window leaves a visual gap rather than shifting other windows. This avoids the complexity of reflowing all windows when any one is removed.

```swift
// Removed: enum SnapSide { case left, right }

final class SnapRegistry {
    private var store: [SnapKey: Int] = [:]   // slot index

    func register(_ key: SnapKey, slot: Int) { … }
    func slot(for key: SnapKey) -> Int? { … }
    func nextSlot() -> Int { (store.values.max() ?? -1) + 1 }
    func remove(_ key: SnapKey) { … }
    func isTracked(_ key: SnapKey) -> Bool { … }
}
```

`nextSlot()` is called under `queue.sync` to guarantee a consistent read.

---

### 2. Frame math in `WindowSnapper`

Each window occupies a fixed width (`visible.width * 0.4`) and is positioned from the right edge of the visible frame:

```
w    = visible.width * 0.4
gap  = 10

axX  = visible.maxX − (slot + 1) × (w + gap)
axY  = primaryHeight − visible.maxY + gap
h    = visible.height − gap × 2
```

Slot 0 (rightmost): `axX = visible.maxX − 1 × (w + gap)`
Slot 1: `axX = visible.maxX − 2 × (w + gap)`
Slot N: `axX = visible.maxX − (N+1) × (w + gap)`

```swift
static func snap() {
    // … get frontmost window …
    let slot = SnapRegistry.shared.nextSlot()
    applyFrame(to: axWindow, slot: slot)
    SnapRegistry.shared.register(key, slot: slot)
    ResizeObserver.shared.observe(window: axWindow, pid: pid, key: key)
}

static func reapply(window: AXUIElement, key: SnapKey) {
    guard let slot = SnapRegistry.shared.slot(for: key) else { return }
    applyFrame(to: window, slot: slot)
}

private static func applyFrame(to window: AXUIElement, slot: Int) { … }
```

---

### 3. Menu bar update

Remove the "Snap Left" button; keep "Snap Right" and "Unsnap":

```swift
Button("Snap Right") { WindowSnapper.snap() }
Button("Unsnap")     { WindowSnapper.unsnap() }
```

---

## Key Technical Notes

- **Slot gaps after unsnap**: Slots are not reclaimed. If slot 0 is unsnapped and a new window is snapped, it becomes slot 1 (or higher), leaving visible space where slot 0 was. This is intentional to avoid shifting existing windows.
- **Width overflow**: At 40% per window, three simultaneously snapped windows span 120% of the visible width; the leftmost will partially overlap the left screen edge. This is acceptable for a PoC — a future plan can introduce dynamic width or a column limit.
- **`nextSlot()` concurrency**: Must be called from the same `queue.sync` path used by other reads to avoid a TOCTOU race between reading the slot and registering the window.
- **`SnapSide` removal**: `ResizeObserver` never referenced `SnapSide` directly, so no changes needed there.

---

## Verification

1. Open Finder. Click **Snap Right** → window occupies the rightmost 40% of the screen.
2. Open Safari. Click **Snap Right** → Safari snaps immediately to the left of Finder, same width, same gap.
3. Open Terminal. Click **Snap Right** → Terminal snaps to the left of Safari.
4. Drag any snapped window → it reapplies its slot position.
5. Click **Unsnap** with Finder focused → Finder can move freely; Safari and Terminal keep their positions.
6. Confirm "Snap Left" is gone from the menu.
