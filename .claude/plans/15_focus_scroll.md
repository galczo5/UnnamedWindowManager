# Plan: 15_focus_scroll — Auto-scroll to focused window's slot

## Checklist

- [ ] Add `kAXFocusedWindowChangedNotification` subscription in `WindowEventMonitor`
- [ ] Add focused-window handler method to `WindowEventMonitor`
- [ ] Add `scheduleOffsetUpdate(forSlot:)` on `CurrentOffset` (poll mouse up → +100 ms → set value)
- [ ] Add `offsetForSlot(_:slots:screen:)` static helper on `CurrentOffset`

---

## Context / Problem

Currently `CurrentOffset` is only changed by explicit scroll actions (`scrollLeft` / `scrollRight`). When the user clicks a window in a slot that is partially or fully off-screen, the layout is not re-centred.

**Goal:** whenever a managed window receives focus, wait for the mouse button to be released, then after an additional 100 ms debounce, compute and apply a new `CurrentOffset` so the focused slot is visible.

---

## Behaviour spec

| Focused slot | New `CurrentOffset` value |
|---|---|
| First slot (index 0) | `0` |
| Last slot | `naturalLeft(last) + lastSlot.width + Config.gap − visible.width` |
| Any other slot | `naturalLeft(si) + slot.width / 2 − visible.width / 2` |

Where `naturalLeft(si)` = `Config.gap + Σ_{i<si}(slot[i].width + Config.gap)` — the left edge of the slot relative to `visible.minX`, before subtracting the offset.

The result is clamped to `≥ 0` (already done by `CurrentOffset.setOffset`).

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Observation/WindowEventMonitor.swift` | Modify — subscribe to `kAXFocusedWindowChangedNotification` per app; add handler |
| `UnnamedWindowManager/Model/CurrentOffset.swift` | Modify — add `scheduleOffsetUpdate(forSlot:)` and `offsetForSlot(_:slots:screen:)` |

---

## Implementation Steps

### 1. Subscribe to `kAXFocusedWindowChangedNotification` in `WindowEventMonitor`

`kAXFocusedWindowChangedNotification` is an **application-level** notification (sent to the `AXUIElementCreateApplication` element, not to individual windows). `WindowEventMonitor` already manages one `AXObserver` per app PID for `kAXWindowCreatedNotification`, so we can add the focus notification to the same observer.

The existing C callback `appWindowCreatedCallback` is wired only for window-created. Add a second C-compatible callback:

```swift
private func appFocusChangedCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,   // the application element
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    // Read the currently focused window from the application element.
    var focusedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
          let focusedWindow = focusedRef,
          CFGetTypeID(focusedWindow as CFTypeRef) == AXUIElementGetTypeID() else { return }
    let axWindow = focusedWindow as! AXUIElement

    WindowEventMonitor.shared.handleFocusChanged(axWindow: axWindow)
}
```

In `subscribe(pid:)`, after adding `kAXWindowCreatedNotification`, also add:

```swift
AXObserverAddNotification(axObs, appElement, kAXFocusedWindowChangedNotification as CFString, nil)
```

### 2. Add `handleFocusChanged(axWindow:)` to `WindowEventMonitor`

```swift
func handleFocusChanged(axWindow: AXUIElement) {
    // Find the ManagedWindow whose stored element matches axWindow.
    guard let key = ResizeObserver.shared.elements.first(where: {
        CFEqual($0.value, axWindow)
    })?.key else { return }

    guard let slotIndex = ManagedSlotRegistry.shared.slotIndex(for: key) else { return }

    CurrentOffset.shared.scheduleOffsetUpdate(forSlot: slotIndex)
}
```

`ResizeObserver.elements` is only accessed on the main thread; the AX run-loop source for this observer is also on the main thread, so this is safe without extra synchronisation.

### 3. Add `scheduleOffsetUpdate(forSlot:)` to `CurrentOffset`

Mirrors the mouse-up polling pattern in `ResizeObserver+Reapply.swift`.

```swift
private var pendingOffsetWork: DispatchWorkItem?

func scheduleOffsetUpdate(forSlot slotIndex: Int) {
    pendingOffsetWork?.cancel()

    let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.pendingOffsetWork = nil

        if NSEvent.pressedMouseButtons != 0 {
            self.scheduleOffsetUpdate(forSlot: slotIndex)
            return
        }

        // Mouse is up — wait 100 ms then apply.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self,
                  let screen = NSScreen.main else { return }
            let slots = ManagedSlotRegistry.shared.allSlots()
            let newOffset = CurrentOffset.offsetForSlot(slotIndex, slots: slots, screen: screen)
            self.setOffset(newOffset)
        }
    }

    pendingOffsetWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
}
```

### 4. Add `offsetForSlot(_:slots:screen:)` to `CurrentOffset`

```swift
static func offsetForSlot(_ slotIndex: Int, slots: [ManagedSlot], screen: NSScreen) -> Int {
    guard !slots.isEmpty else { return 0 }
    let visible = screen.visibleFrame

    // naturalLeft: left edge of slot relative to visible.minX, ignoring current offset.
    func naturalLeft(_ si: Int) -> CGFloat {
        var x = Config.gap
        for i in 0..<si { x += slots[i].width + Config.gap }
        return x
    }

    if slotIndex == 0 {
        return 0
    } else if slotIndex == slots.count - 1 {
        let left = naturalLeft(slotIndex)
        let raw  = left + slots[slotIndex].width + Config.gap - visible.width
        return Int(max(0, raw))
    } else {
        let left = naturalLeft(slotIndex)
        let raw  = left + slots[slotIndex].width / 2 - visible.width / 2
        return Int(max(0, raw))
    }
}
```

---

## Key Technical Notes

- `kAXFocusedWindowChangedNotification` fires on the **application element**, not the window element. The focused window must be read via `kAXFocusedWindowAttribute`.
- All AX callbacks are delivered on the main run loop (observer source added to `CFRunLoopGetMain`), so `ResizeObserver.elements` can be read safely without locks.
- `pendingOffsetWork` cancels any in-flight poll when a new focus event arrives, preventing stale offset updates.
- The 100 ms delay after mouse-up intentionally allows `reapplyAll` (triggered by a preceding drag/move) to settle before the offset changes.
- `setOffset` already clamps to `≥ 0` and calls `WindowSnapper.reapplyAll()`, so no extra reapply is needed.
- The `naturalLeft` helper purposely ignores `CurrentOffset.shared.value` — it computes the layout-coordinate position, which is then compared against `visible.width` to derive the correct new offset.

---

## Verification

1. Launch the app with three or more managed windows across multiple slots.
2. Click the window in the **last slot** → after mouse release + ~100 ms, the layout scrolls so the last slot is visible at the right edge.
3. Click the window in the **first slot** → offset resets to 0, first slot is flush left.
4. Click a **middle slot** window → that slot centres horizontally on screen.
5. Scroll manually with the scroll keys, then click a window — offset updates correctly regardless of previous scroll position.
6. Rapid-click between two windows — only one offset update fires (pending work item is cancelled and re-issued).
