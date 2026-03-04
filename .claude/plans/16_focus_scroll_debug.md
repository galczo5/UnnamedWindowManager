# Plan: 16_focus_scroll_debug — Fix focus-triggered scroll not firing for terminal windows

## Checklist

- [ ] Add logging to `appNotificationCallback` to confirm which notifications arrive
- [ ] Add logging to `appActivated` to confirm it fires on app switch
- [ ] Add logging to `handleFocusChanged` to trace guard failures
- [ ] Add logging to `scheduleOffsetUpdate` entry and mouse-up resolution
- [ ] Identify which guard is silently dropping the event
- [ ] Fix the root cause based on findings
- [ ] Remove all diagnostic logging

---

## Context / Problem

Plan 15 added focus-triggered auto-scroll: when a managed window is focused, `CurrentOffset` is updated so the window's slot is visible. Two symptoms persist:

1. **Single terminal window** — clicking the active app's window fires no scroll (app was already active, `didActivateApplicationNotification` does not re-fire; `kAXFocusedWindowChangedNotification` does not fire because the focused window did not change within the app).
2. **Second window of the same app** — clicking a second managed window of the already-active app produces no scroll. `kAXMainWindowChangedNotification` and `kAXFocusedWindowChangedNotification` were added to handle this, but the scroll still does not fire.

Additionally, unminimization side effects are suspected: when `setOffset` → `reapplyAll` → `applyVisibility` restores an auto-minimized window, that window briefly steals focus, firing a second focus notification for the wrong slot. `isSuppressingFocusScroll` was added to block this, but if suppression fires too early it also blocks the legitimate user-initiated event.

**Goal:** determine exactly where the event is being dropped, fix it, and verify both single-window and multi-window scenarios work.

---

## macOS AX notification behaviour

| Scenario | Expected notification |
|---|---|
| Click window of a *different* app | `NSWorkspace.didActivateApplicationNotification` on new app |
| Click a *different window* within the *same* active app | `kAXFocusedWindowChangedNotification` + `kAXMainWindowChangedNotification` on app element |
| Click the *same* window that is already focused | **No AX notification at all** |
| Window restored from programmatic minimization | `kAXFocusedWindowChangedNotification` may fire if app gives it focus |

The third row is the root cause of symptom 1: there is no AX event to intercept when the user clicks the window that is already the focused window of the already-active app.

For symptom 1 a different signal is needed — either a global mouse-down event tap or accepting that no scroll fires when re-clicking an already-focused window.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Observation/WindowEventMonitor.swift` | Modify — add logging; fix event gap for already-focused window |
| `UnnamedWindowManager/Model/CurrentOffset.swift` | Modify — add logging; fix suppression window timing |

---

## Implementation Steps

### 1. Add diagnostic logging

Wrap every decision point with `print` statements so the console shows exactly what fires and where it is dropped.

In `appNotificationCallback`:
```swift
print("[Focus] notification=\(notification) element=\(element)")
```

In `appActivated`:
```swift
print("[Focus] appActivated pid=\(pid) foundFocusedWindow=\(focusedRef != nil)")
```

In `handleFocusChanged`:
```swift
print("[Focus] handleFocusChanged suppressed=\(CurrentOffset.shared.isSuppressingFocusScroll)")
// after guard 1:
print("[Focus] key=\(key)")
// after guard 2:
print("[Focus] slotIndex=\(slotIndex)")
```

In `scheduleOffsetUpdate` (in `CurrentOffset`):
```swift
print("[Offset] scheduleOffsetUpdate slot=\(slotIndex)")
// inside the work item after mouse check:
print("[Offset] mouse up, applying offset for slot=\(slotIndex)")
```

### 2. Exercise each scenario and read the log

Run the app, snap two or more windows, then:
- Switch to a different app → switch back (should log `appActivated`)
- Within same app, click second window (should log `kAXFocusedWindowChangedNotification` or `kAXMainWindowChangedNotification`)
- Re-click the already-focused window (nothing will log — this confirms symptom 1)

### 3. Fix symptom 1 — re-clicking the already-focused window

Because no AX event fires when the user clicks a window that is already the app's focused window, use a global `NSEvent` monitor for `mouseDown` as a supplemental signal.

On every left-mouse-down, find the window under the cursor via `AXUIElementCopyAttributeValue(systemWide, kAXFocusedWindowAttribute…)` and call `handleFocusChanged` if it matches a managed window.

```swift
// In WindowEventMonitor.start():
NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
    let systemWide = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedWindowAttribute as CFString, &focusedRef
          ) == .success,
          let focusedRef,
          CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return }
    self?.handleFocusChanged(axWindow: focusedRef as! AXUIElement)
}
```

This fires on every left-click anywhere on screen, but `handleFocusChanged` already exits early for unmanaged windows, so the cost is negligible.

### 4. Fix the suppression window

The current `suppressFocusScroll(for: 0.6)` in `setOffset` blocks legitimate user clicks for 600 ms after any scroll — enough to swallow a quick window switch. Shorten the suppression to cover only the unminimization delay (~200 ms) and start it only when `applyVisibility` actually restores a window, not on every `setOffset` call.

Remove the `suppressFocusScroll` call from `setOffset`. Instead, call it from `WindowVisibilityManager.applyVisibility` immediately before each `setMinimized(false, …)`:

```swift
// In applyVisibility, before restoring a window:
CurrentOffset.shared.suppressFocusScroll(for: 0.25)
setMinimized(false, window: axWindow)
```

### 5. Remove diagnostic logging

Once the root cause is confirmed and fixed, delete all `print` statements added in step 1.

---

## Key Technical Notes

- Re-clicking an already-focused window of the already-active app produces **zero** AX notifications — the global `mouseDown` monitor is the only reliable signal for this case.
- `NSEvent.addGlobalMonitorForEvents` requires Accessibility permission and delivers events asynchronously on the main thread.
- `AXUIElementCreateSystemWide()` + `kAXFocusedWindowAttribute` returns the frontmost window across all apps — safe to call from a mouse-down handler since it happens after the OS has updated focus.
- The suppression flag must only block focus events that originate from *our* unminimization, not from user input. Triggering it per-restore rather than per-setOffset achieves this.
- `handleFocusChanged` is idempotent — calling it from both the AX notification path and the mouse-down path for the same click is harmless; the second call just cancels and reschedules the same work item.

---

## Verification

1. Snap two windows from different apps into two slots → click back and forth → each click scrolls to the correct slot.
2. Snap two windows from the **same** app (e.g., two terminal windows) into separate slots → click each → each click scrolls to the correct slot.
3. Re-click the **already-focused** window → scroll fires (handled by mouse-down monitor).
4. Scroll manually with keyboard shortcut → within 250 ms, click a window → scroll fires correctly (suppression window short enough).
5. Have an auto-minimized window in slot 3; scroll to slot 2 → slot 3 window is restored → slot 2 remains in view (suppression prevents slot 3 from hijacking the offset).
