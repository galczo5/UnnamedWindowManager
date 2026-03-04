# Plan: 13_hide_windows — Auto-Minimize Off-Screen Slots

## Checklist

- [x] Create `WindowVisibilityManager.swift` — tracks auto-minimized windows; exposes `applyVisibility(slots:)` and `windowRemoved(_:)`
- [x] Update `WindowSnapper.reapplyAll()` — pass slot snapshot to `applyVisibility` after repositioning
- [x] Update `WindowSnapper.unsnap()` — restore window if it was auto-minimized before releasing it from the registry
- [x] Update `ResizeObserver.swift` destroy handler — call `WindowVisibilityManager.shared.windowRemoved(_:)` to purge closed windows from the tracking set
- [x] Update `WindowSnapper.snap()` and `organize()` — call `reapplyAll()` at the end so visibility is applied after initial snap
- [x] Fix restore path — un-minimize window **before** re-applying position so macOS honors the new coordinates

---

## Problem

When many windows are snapped, the rightmost slots may extend beyond the right edge of the visible screen. Currently those windows sit off-screen but remain unminimized — they clutter the Dock, intercept keyboard shortcuts, and hold focus accidentally.

The feature: any slot whose left edge is at or beyond `visible.maxX` (i.e., 100 % off-screen to the right) should have all its windows automatically minimized. When the layout changes and such a slot moves back on-screen, those windows should be restored.

---

## macOS capability note

macOS does **not** support hiding a single window independently of its application. `kAXHiddenAttribute` is application-level and hides every window of the app at once.

Per-window minimization via `kAXMinimizedAttribute = true` is the correct mechanism. It:
- minimizes the specific window to the Dock (thumbnail visible)
- leaves all other windows of the same app visible
- can be reversed by setting `kAXMinimizedAttribute = false`

---

## Behaviour spec

| Situation | Expected result |
|-----------|----------------|
| Slot's left edge >= `visible.maxX` | All windows in that slot are minimized; added to auto-minimize tracking set |
| Slot moves back on-screen (layout change) | Windows in the tracking set for that slot are restored (un-minimized); removed from set |
| Window was already minimized by the user before we touch it | Not tracked; not restored by us (guard: only restore windows we minimized) |
| Window is closed while auto-minimized | Tracking set entry is purged; no attempt to restore a destroyed element |
| Window is manually unsnaped while auto-minimized | Restored before being released from the registry |
| Only rightmost off-screen slots are affected | Left-to-right layout means only the trailing overflow is minimized; first slot is always on-screen |

---

## Off-screen detection

`applyPosition` already computes xOffset per slot the same way as `xRange`:

```
xOffset = visible.minX + gap
          + (slot[0].width + gap)
          + (slot[1].width + gap)
          + ...
```

A slot at index `i` is **fully off-screen** when its `xOffset` ≥ `visible.maxX`.

---

## Files to modify

| File | Action |
|------|--------|
| `WindowVisibilityManager.swift` | **New file** — auto-minimize logic and tracking set |
| `WindowSnapper.swift` | Pass slots to `applyVisibility` at end of `reapplyAll()`; restore in `unsnap()` |
| `ResizeObserver.swift` | Call `WindowVisibilityManager.shared.windowRemoved(_:)` in destroy handler |

---

## Implementation

### 1. `WindowVisibilityManager.swift` — new file

```swift
//
//  WindowVisibilityManager.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

final class WindowVisibilityManager {
    static let shared = WindowVisibilityManager()
    private init() {}

    /// Windows minimized automatically because their slot is off-screen.
    /// Keyed by ManagedWindow identity so we can restore them later.
    private var autoMinimized: Set<ManagedWindow> = []

    /// Call after every reapplyAll(). Minimizes windows in off-screen slots;
    /// restores windows whose slots have come back on-screen.
    /// Accepts the same slot snapshot already read by reapplyAll() to avoid a second registry read.
    func applyVisibility(slots: [ManagedSlot]) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame

        var xOffset = visible.minX + Config.gap
        for slot in slots {
            let isOffScreen = xOffset >= visible.maxX
            for win in slot.windows {
                guard let axWindow = ResizeObserver.shared.window(for: win) else { continue }
                if isOffScreen {
                    if !autoMinimized.contains(win) {
                        setMinimized(true, window: axWindow)
                        autoMinimized.insert(win)
                    }
                } else {
                    if autoMinimized.contains(win) {
                        setMinimized(false, window: axWindow)
                        autoMinimized.remove(win)
                    }
                }
            }
            xOffset += slot.width + Config.gap
        }
    }

    /// Restores a window if it was auto-minimized, then removes it from tracking.
    /// Call before releasing a window from the registry (e.g. unsnap).
    func restoreAndForget(_ key: ManagedWindow) {
        guard autoMinimized.contains(key) else { return }
        if let axWindow = ResizeObserver.shared.window(for: key) {
            setMinimized(false, window: axWindow)
        }
        autoMinimized.remove(key)
    }

    /// Removes a closed window from the tracking set without attempting to restore it.
    /// Call from the destroy handler after the AX element is no longer valid.
    func windowRemoved(_ key: ManagedWindow) {
        autoMinimized.remove(key)
    }

    private func setMinimized(_ minimized: Bool, window: AXUIElement) {
        let value = minimized as CFBoolean
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, value)
    }
}
```

**Thread safety**: `applyVisibility`, `restoreAndForget`, and `windowRemoved` are always called from the same paths as `reapplyAll()` and the destroy handler (neither of which impose a specific thread guarantee today). Because `autoMinimized` is mutated from at most one call site at a time in practice, and AX attribute writes are internally serialized by the framework, no additional locking is introduced here — consistent with the existing `elements` dict in `ResizeObserver`. If threading issues arise, wrapping with a serial `DispatchQueue` follows the same pattern as `ManagedSlotRegistry.queue`.

---

### 2. `WindowSnapper.swift` — wire up visibility after reapply

#### 2a. `reapplyAll` — append visibility pass

```swift
static func reapplyAll() {
    let slots = ManagedSlotRegistry.shared.allSlots()
    for slot in slots {
        for win in slot.windows {
            guard let axWindow = ResizeObserver.shared.window(for: win) else { continue }
            applyPosition(to: axWindow, key: win, slots: slots)
        }
    }
    WindowVisibilityManager.shared.applyVisibility(slots: slots)
}
```

The slot snapshot is read once and shared with both the position pass and the visibility pass — no second registry read.

#### 2b. `unsnap` — restore before release

```swift
static func unsnap() {
    guard AXIsProcessTrusted() else { return }
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
    let pid = frontApp.processIdentifier
    let axApp = AXUIElementCreateApplication(pid)

    var focusedWindow: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else { return }
    let axWindow = focusedWindow as! AXUIElement

    let key = managedWindow(for: axWindow, pid: pid)
    WindowVisibilityManager.shared.restoreAndForget(key)   // ← new
    ManagedSlotRegistry.shared.remove(key)
    ResizeObserver.shared.stopObserving(key: key, pid: pid)
}
```

Restoring before `remove` ensures `ResizeObserver.shared.window(for:)` still resolves the AX element inside `restoreAndForget`.

---

### 3. `ResizeObserver.swift` — purge on window close

In the destroy handler, after `cleanup(key:pid:)`:

```swift
if notification == kElementDestroyed as String {
    if let screen = NSScreen.main {
        ManagedSlotRegistry.shared.removeAndReflow(key, screen: screen)
    } else {
        ManagedSlotRegistry.shared.remove(key)
    }
    cleanup(key: key, pid: pid)
    WindowVisibilityManager.shared.windowRemoved(key)   // ← new
    WindowSnapper.reapplyAll()
    return
}
```

`windowRemoved` is called **after** `cleanup` because `cleanup` already invalidates `ResizeObserver.shared.window(for: key)`. No AX call is attempted — the element is destroyed.

---

## Key technical notes

- **Only right-side overflow**: The current layout model places slots left-to-right from `visible.minX`. There is no mechanism to produce a slot with a negative xOffset, so only right-side overflow is possible. If scroll/pan is introduced later, the same `xOffset >= visible.maxX` test applies naturally.
- **Partial overlap not minimized**: A slot whose left edge is still on-screen (`xOffset < visible.maxX`) is left visible even if its right edge overflows. The condition "100 % off-screen" means the **left edge** is at or past `visible.maxX`.
- **User-minimized windows are safe**: `autoMinimized` only contains windows we minimized. A user-minimized window that happens to land in an off-screen slot is skipped by the `!autoMinimized.contains(win)` guard — we never restore it.
- **Slot order is stable**: `ManagedSlotRegistry.allSlots()` returns `slots` in array order, which is left-to-right by construction. xOffset accumulation in `applyVisibility` mirrors `applyPosition` exactly.
- **`snapLeft` path**: `snapLeft` calls `reapplyAll()` at the end, which now calls `applyVisibility`. No separate hook needed.
- **`snap` and `organize` paths**: Both now call `reapplyAll()` at the end, which triggers `applyVisibility`. Off-screen slots are minimized immediately after initial snapping.

---

## Restore + reposition on layout change

### Problem

Any action that brings an off-screen slot back into view (window close, resize, unsnap of a left-side window) triggers `reapplyAll()`. The current order inside `reapplyAll()` is:

1. `applyPosition` for all windows (including currently minimized ones)
2. `applyVisibility` — un-minimizes windows whose slot is now on-screen

macOS **ignores position and size changes on minimized windows**. So by the time `applyVisibility` calls `setMinimized(false, ...)`, the window appears at its pre-minimize position rather than the correct on-screen slot coordinates.

### Fix

In `applyVisibility`, when restoring a window, un-minimize it **first**, then immediately call `applyPosition` so the window materializes at the correct slot coordinates.

```swift
// In the restore branch of applyVisibility:
if autoMinimized.contains(win) {
    setMinimized(false, window: axWindow)          // un-minimize first
    WindowSnapper.applyPosition(to: axWindow, key: win, slots: slots)  // then reposition
    autoMinimized.remove(win)
}
```

`applyVisibility` already receives the `slots` snapshot from `reapplyAll()`, so it can pass it directly to `applyPosition` without a second registry read.

### Files to modify

| File | Action |
|------|--------|
| `WindowVisibilityManager.swift` | Accept `slots` in restore branch; call `applyPosition` after `setMinimized(false)` |

### Updated `applyVisibility` signature and restore branch

```swift
func applyVisibility(slots: [ManagedSlot]) {
    guard let screen = NSScreen.main else { return }
    let visible = screen.visibleFrame

    var xOffset = visible.minX + Config.gap
    for (si, slot) in slots.enumerated() {
        let isOffScreen = xOffset >= visible.maxX
        if slot.hidden != isOffScreen {
            ManagedSlotRegistry.shared.setHidden(isOffScreen, forSlotAt: si)
        }
        for win in slot.windows {
            guard let axWindow = ResizeObserver.shared.window(for: win) else { continue }
            if isOffScreen {
                if !autoMinimized.contains(win) {
                    setMinimized(true, window: axWindow)
                    autoMinimized.insert(win)
                }
            } else {
                if autoMinimized.contains(win) {
                    setMinimized(false, window: axWindow)                        // ← un-minimize first
                    WindowSnapper.applyPosition(to: axWindow, key: win, slots: slots)  // ← then reposition
                    autoMinimized.remove(win)
                }
            }
        }
        xOffset += slot.width + Config.gap
    }
}
```

---

## Verification

1. **Basic minimize**: Snap four narrow windows side by side such that the rightmost extends past the screen right edge. The off-screen window minimizes to the Dock automatically.
2. **Restore on layout change**: After step 1, close or unsnap one of the left windows. The layout reflows; the formerly off-screen window is now on-screen. It un-minimizes automatically.
3. **User-minimized window preserved**: Manually minimize a window. Snap enough others to push it off-screen. When the layout reflows and the slot comes back on-screen, the user-minimized window stays minimized (we did not track it).
4. **Multiple windows in off-screen slot**: Snap a slot with two vertically stacked windows at an off-screen position. Both are minimized. When the slot returns on-screen, both are restored.
5. **Unsnap from off-screen slot**: Focus a window in an off-screen (minimized) slot via the Dock; unsnap it. It is restored to visible state and released from the registry cleanly.
6. **Close off-screen window**: Close a minimized off-screen window directly from the Dock. The destroy handler fires; `windowRemoved` purges it from the tracking set. No crash or stale reference.
7. **On-screen slots unaffected**: Normal on-screen windows are never touched by `applyVisibility` (their `isOffScreen` is `false` and they are not in `autoMinimized`).
8. **Restore repositions correctly**: Resize a left-side window to make it narrower. A formerly off-screen slot comes on-screen. The restored window appears at the correct slot position, not at its pre-minimize coordinates.
9. **Move triggers restore**: Drag a snapped window to make room. The restored window materializes at the right position immediately after mouse-up.
