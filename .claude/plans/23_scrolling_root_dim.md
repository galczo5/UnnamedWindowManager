# Plan: 23_scrolling_root_dim — Dim Side Slots in ScrollingRoot, Center Slot Stays Above

## Checklist

- [x] Add `scrollingRootInfo(containing:)` to `ScrollingTileService`
- [x] Update `FocusObserver.executeDim` to handle ScrollingRoot windows

---

## Context / Problem

Currently `FocusObserver.executeDim` explicitly excludes ScrollingRoot windows from dimming:
if `ScrollingTileService.isTracked(key)` is true the code calls `restoreAll()` and returns.

The desired behavior: when a window in a ScrollingRoot is focused, the dim overlay should
still appear, but the **center slot window** is ordered above the overlay, while side slot
windows (left/right stacks) remain below it and are therefore visually dimmed.

`WindowOpacityService.dim(rootID:focusedHash:)` already implements the right primitive:
`win.order(.below, relativeTo: Int(focusedHash))` places the overlay just below the named
window. We just need to supply the center slot's window hash instead of the focused window's.

---

## Behaviour Spec

- Any time a window belonging to a ScrollingRoot gains focus, dim is applied.
- The overlay is ordered directly below the center slot window → center looks undimmed.
- Side slot windows (left/right) are positioned behind center, so they end up below the
  overlay and appear dimmed.
- Which slot the focused window lives in does not matter — center is always the anchor.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/ScrollingTileService.swift` | Add `scrollingRootInfo(containing:)` |
| `UnnamedWindowManager/Observation/FocusObserver.swift` | Update `executeDim` to call dim for ScrollingRoot |

---

## Implementation Steps

### 1. Add `scrollingRootInfo(containing:)` to `ScrollingTileService`

Returns the root UUID and the center slot's window hash for any window tracked in a
ScrollingRoot. Returns `nil` if the key is not in any scrolling root or center is empty.

```swift
func scrollingRootInfo(containing key: WindowSlot) -> (rootID: UUID, centerHash: UInt)? {
    store.queue.sync {
        for (id, rootSlot) in store.roots {
            guard case .scrolling(let root) = rootSlot,
                  containsWindow(key, in: root) else { continue }
            switch root.center {
            case .window(let w):       return (id, w.windowHash)
            case .stacking(let s):     return s.children.first.map { (id, $0.windowHash) }
            default:                   return nil
            }
        }
        return nil
    }
}
```

### 2. Update `FocusObserver.executeDim`

Replace the `!ScrollingTileService.shared.isTracked(key)` guard with an explicit branch:

```swift
private func executeDim(pid: pid_t) {
    let axApp = AXUIElementCreateApplication(pid)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success
    else {
        WindowOpacityService.shared.restoreAll()
        return
    }
    let axWindow = ref as! AXUIElement

    let elements = ResizeObserver.shared.elements
    guard let (key, _) = elements.first(where: { CFEqual($0.value, axWindow) }) else {
        WindowOpacityService.shared.restoreAll()
        return
    }

    if let info = ScrollingTileService.shared.scrollingRootInfo(containing: key) {
        WindowOpacityService.shared.dim(rootID: info.rootID, focusedHash: info.centerHash)
    } else if let rootID = TileService.shared.rootID(containing: key) {
        WindowOpacityService.shared.dim(rootID: rootID, focusedHash: key.windowHash)
    } else {
        WindowOpacityService.shared.restoreAll()
    }
}
```

---

## Key Technical Notes

- `isTracked` is removed from `executeDim` — `scrollingRootInfo` already returns nil for
  non-scrolling-root windows, so the two checks are no longer separate.
- The center slot is always `.window` in practice (addWindow always sets `root.center = .window(newWin)`),
  but the stacking fallback is handled defensively.
- `WindowOpacityService.dim` positions the overlay below `focusedHash` via
  `win.order(.below, relativeTo:)` — no changes needed there.
- Side windows physically reside behind/under center on screen, so ordering the overlay
  below center is sufficient to cover them.

---

## Verification

1. Create a ScrollingRoot with two or more windows (scroll command at least twice).
2. Click the center window — sides should dim, center stays bright.
3. Click a side window — center should still appear above the dim overlay, side stays dim.
4. Scroll to bring a different window to center — after scroll, the new center should be
   undimmed and old center (now in a side slot) should be dimmed.
5. Switch focus to a non-tiled window — dim overlay fades out for all roots.
6. Verify tiling root dim still works normally (regression check).
