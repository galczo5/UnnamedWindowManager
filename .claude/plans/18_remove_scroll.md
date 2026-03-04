# Plan: 18_remove_scroll — Remove Scroll Feature and All Related Code

## Checklist

- [ ] Delete `CurrentOffset.swift`
- [ ] Remove `ManagedSlot.hidden` field from `ManagedTypes.swift`
- [ ] Remove `setHidden(_:forSlotAt:)` from `ManagedSlotRegistry.swift`
- [ ] Remove scroll offset from `applyPosition` in `SnapLayout.swift`
- [ ] Remove scroll offset from `xRange` in `SnapLayout.swift`
- [ ] Remove scroll offset and `hidden` tag from `applyVisibility` in `WindowVisibilityManager.swift`
- [ ] Simplify `WindowEventMonitor` — remove focus-scroll logic, keep focus logging
- [ ] Remove "Scroll Left" / "Scroll Right" menu items from `UnnamedWindowManagerApp.swift`
- [ ] Remove scroll offset from Debug xOffset calculation in `UnnamedWindowManagerApp.swift`
- [ ] Remove `hidden` tag from Debug slot display in `UnnamedWindowManagerApp.swift`

---

## Context / Problem

Plans 14–16 added a horizontal scroll feature: `CurrentOffset` singleton, "Scroll Left/Right" menu actions, focus-triggered auto-scroll, and `hidden` slot tracking. The feature is being removed entirely. `Logger.swift` and all logging calls must remain intact.

### Why scroll is being removed — pivot to traditional tiling

The scrollable workspace model (à la Niri / PaperWM) is being abandoned in favour of more traditional tiling window management. macOS is fundamentally hostile to this approach: the Accessibility and window-management APIs were not designed for scrollable infinite canvases, and working around the platform's assumptions (Space switching, Mission Control, window animations, focus handling) produces fragile, unreliable behaviour. The effort required to make it feel native would almost certainly end with a result that is still not usable day-to-day. The project is therefore pivoting to a layout model closer to conventional tiling WMs — fixed slots, no horizontal scroll — which works *with* macOS rather than against it.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Model/CurrentOffset.swift` | **Delete** — entire file |
| `UnnamedWindowManager/Model/ManagedTypes.swift` | Remove `hidden` field from `ManagedSlot` |
| `UnnamedWindowManager/Model/ManagedSlotRegistry.swift` | Remove `setHidden(_:forSlotAt:)` method |
| `UnnamedWindowManager/Snapping/SnapLayout.swift` | Revert `xOffset` to `visible.minX + Config.gap` in `applyPosition` and `xRange` |
| `UnnamedWindowManager/Observation/WindowVisibilityManager.swift` | Revert `xOffset` starting value; remove `setHidden` call |
| `UnnamedWindowManager/Observation/WindowEventMonitor.swift` | Remove `handleFocusChanged` scroll logic; keep focus log line; remove `isSuppressingFocusScroll` guard |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Remove "Scroll Left/Right" buttons; revert Debug xOffset; remove `hidden` tag |

---

## Implementation Steps

### 1. Delete `CurrentOffset.swift`

Remove the file from the project. All references to `CurrentOffset.shared` will become compile errors that drive the remaining steps.

### 2. `ManagedTypes.swift` — remove `hidden` from `ManagedSlot`

```swift
// Before:
struct ManagedSlot {
    var order: Int = 0
    var width: CGFloat
    var windows: [ManagedWindow]
    var hidden: Bool = false
}

// After:
struct ManagedSlot {
    var order: Int = 0
    var width: CGFloat
    var windows: [ManagedWindow]
}
```

### 3. `ManagedSlotRegistry.swift` — remove `setHidden`

Delete the `setHidden(_:forSlotAt:)` method entirely (the one that sets `slots[index].hidden`).

### 4. `SnapLayout.swift` — revert xOffset in `applyPosition` and `xRange`

```swift
// applyPosition (and xRange) — before:
var xOffset = visible.minX + Config.gap - CGFloat(CurrentOffset.shared.value)

// after:
var xOffset = visible.minX + Config.gap
```

Two call sites: one in `applyPosition`, one in `xRange`.

### 5. `WindowVisibilityManager.swift` — revert xOffset and remove `setHidden` call

```swift
// before:
var xOffset = visible.minX + Config.gap - CGFloat(CurrentOffset.shared.value)
for (si, slot) in slots.enumerated() {
    let isOffScreen = xOffset >= visible.maxX
    if slot.hidden != isOffScreen {
        ManagedSlotRegistry.shared.setHidden(isOffScreen, forSlotAt: si)
    }
    ...
}

// after:
var xOffset = visible.minX + Config.gap
for slot in slots {
    let isOffScreen = xOffset >= visible.maxX
    for win in slot.windows {
    ...
    }
    xOffset += slot.width + Config.gap
}
```

Drop the `(si, slot)` enumeration (no longer needed for `setHidden`) and revert to `for slot in slots`.

### 6. `WindowEventMonitor.swift` — remove focus-scroll, keep logging

`handleFocusChanged` currently: guards on `isSuppressingFocusScroll`, reads actual position/size, logs, then calls `CurrentOffset.shared.scheduleOffsetUpdate`. After removal:

- Drop the `isSuppressingFocusScroll` guard entirely.
- Keep the log line (`Logger.shared.log("[focus] ...")`).
- Remove the `scheduleOffsetUpdate` call and the position/size read that was only used for the log detail (simplify to just log slot index and title if desired, or keep the full read — keep whatever preserves the log).
- Remove the `appActivated` handler if its sole purpose was focus-scroll triggering. Check: it calls `handleFocusChanged` → which now only logs → keep it if useful for debugging, remove if it adds no value.

After removal `handleFocusChanged` becomes a simple logger call. The `appActivated` observer can be removed since it served only to trigger scroll.

```swift
func handleFocusChanged(axWindow: AXUIElement) {
    guard let key = ResizeObserver.shared.elements.first(where: {
        CFEqual($0.value, axWindow)
    })?.key else { return }
    guard let slotIndex = ManagedSlotRegistry.shared.slotIndex(for: key) else { return }
    Logger.shared.log("[focus] id=\(key.windowHash) slot=\(slotIndex)")
}
```

Remove `appActivated` observer registration in `start()` and the `@objc private func appActivated` method.

### 7. `UnnamedWindowManagerApp.swift` — menu and Debug

Remove the two scroll buttons:

```swift
// Remove these two lines:
Button("Scroll Left")  { CurrentOffset.shared.scrollLeft()  }
Button("Scroll Right") { CurrentOffset.shared.scrollRight() }
```

Revert Debug xOffset:

```swift
// Before:
var xOffset = (visible?.minX ?? 0) + Config.gap - CGFloat(CurrentOffset.shared.value)

// After:
var xOffset = (visible?.minX ?? 0) + Config.gap
```

Remove the `hidden` tag in the slot display line:

```swift
// Before:
let hiddenTag = slot.hidden ? "  (hidden)" : ""
lines.append(String(format: "── Slot %d  x %.1f  width %.1f\(hiddenTag) ──", si, xOffset, slot.width))

// After:
lines.append(String(format: "── Slot %d  x %.1f  width %.1f ──", si, xOffset, slot.width))
```

---

## Key Technical Notes

- `CurrentOffset.shared` appears in five files; deleting the file first makes the compiler enumerate every remaining reference.
- `ManagedSlot.hidden` is only set via `setHidden` (called from `applyVisibility`) and read in the Debug display. Both are removed together.
- `WindowEventMonitor.appActivated` was introduced solely for focus-scroll. Removing it eliminates an unnecessary AX query on every app switch.
- Logger calls inside `handleFocusChanged` use `key.windowHash` and `slotIndex` — both remain available after removing scroll logic, so the log line can be kept or simplified freely.
- No other file references `CurrentOffset`, `slot.hidden`, or `setHidden` — confirmed by grep.

---

## Verification

1. Build succeeds with no references to `CurrentOffset`, `hidden`, or `setHidden`.
2. Snap several windows → they position correctly at `visible.minX + Config.gap` with no offset.
3. Menu shows Snap / Unsnap / Organize / Debug / Quit — no Scroll items.
4. Debug alert shows slot positions without `(hidden)` tags.
5. Focus a snapped window → log shows `[focus]` entry; no scroll/reapply triggered.
6. Auto-minimize still works: snap enough windows to push a slot off the right edge → it minimizes. Close a left window → off-screen slot comes back → window restores at correct position.
