# Plan: 14_screen_change_reflow — Reflow Layout on Screen Size Change

## Checklist

- [x] Add `recomputeVisibleRootSizes(screen:)` to `SnapService`
- [x] Create `ScreenChangeObserver` that observes screen parameter changes
- [x] Start observer in `UnnamedWindowManagerApp.init()`

---

## Context / Problem

When the user changes display resolution, connects an external monitor, or disconnects one, `NSScreen.visibleFrame` changes. The slot tree's stored pixel sizes (in `RootSlot`, `HorizontalSlot`, `VerticalSlot`, `WindowSlot`) become stale — they still reflect the old screen dimensions.

The goal is to detect screen configuration changes and recompute all slot sizes based on the new screen dimensions, then reapply the layout so windows are repositioned and resized correctly.

---

## macOS capability note

macOS posts `NSApplication.didChangeScreenParametersNotification` when screens are added, removed, or resized. This notification arrives on the main thread.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/SnapService.swift` | Modify — add `recomputeVisibleRootSizes(screen:)` |
| `UnnamedWindowManager/Observation/ScreenChangeObserver.swift` | **New file** — observes screen parameter changes and triggers reflow |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — start `ScreenChangeObserver` in `init()` |

---

## Implementation Steps

### 1. Add `recomputeVisibleRootSizes` to `SnapService`

The existing `recomputeSizes` calls in `SnapService` (e.g. in `snap`, `resize`, `removeAndReflow`) all follow the same pattern. Add a public method to do the same for the visible root using a new screen frame.

```swift
func recomputeVisibleRootSizes(screen: NSScreen) {
    store.queue.sync(flags: .barrier) {
        guard let id = visibleRootID() else { return }
        position.recomputeSizes(&store.roots[id]!,
                                width: screen.visibleFrame.width  - Config.gap * 2,
                                height: screen.visibleFrame.height - Config.gap * 2)
    }
}
```

### 2. Create `ScreenChangeObserver`

New file. Observes `NSApplication.didChangeScreenParametersNotification`. On change, recomputes sizes and reapplies the layout.

```swift
// Observes screen configuration changes (resolution, display connect/disconnect)
// and reflows the layout to match the new screen dimensions.
final class ScreenChangeObserver {
    static let shared = ScreenChangeObserver()
    private init() {}

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        guard let screen = NSScreen.main else { return }
        SnapService.shared.recomputeVisibleRootSizes(screen: screen)
        ReapplyHandler.reapplyAll()
    }
}
```

### 3. Start observer in app init

Add `ScreenChangeObserver.shared.start()` to `UnnamedWindowManagerApp.init()`.

---

## Key Technical Notes

- `NSApplication.didChangeScreenParametersNotification` fires on the main thread, so no dispatch needed before AppKit calls like `NSScreen.main`.
- `ReapplyHandler.reapplyAll()` already calls `pruneOffScreenWindows`, `applyLayout`, and posts `snapStateChanged` — no extra logic needed.
- If no root is visible (no snapped windows), `recomputeVisibleRootSizes` is a no-op, so the notification can be ignored safely.
- `NSScreen.main` returns the screen with the key window, which is the correct screen to use since the layout is always for the visible root.

---

## Verification

1. Snap two windows side by side.
2. Change display resolution in System Settings → the windows should resize to fill the new screen dimensions.
3. Connect an external monitor, move a snapped window to it, snap another window → screen change on the built-in display should not affect the external layout and vice versa.
4. Disconnect the external monitor → windows that were on it are pruned; remaining snapped windows reflow to the built-in screen.
