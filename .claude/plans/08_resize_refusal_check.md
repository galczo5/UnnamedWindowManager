# Plan: 08_resize_refusal_check — Detect and Fix Windows That Refuse to Resize

## Checklist

- [x] Add `NotificationService.swift` with `UNUserNotificationCenter` wrapper
- [x] Request notification authorization in `UnnamedWindowManagerApp.init()`
- [x] Add `Observation/PostResizeValidator.swift` with `PostResizeValidator.checkAndFixRefusals(windows:screen:)`
- [x] Schedule refusal check from `scheduleReapplyWhenMouseUp` after resize reapply

---

## Context / Problem

After a user drag-resize, `ReapplyHandler.reapplyAll()` writes target sizes to every snapped window via `AXUIElementSetAttributeValue`. Some windows (e.g. terminal emulators, apps with minimum-size constraints) silently ignore the request and remain at a different size. This causes the slot layout to disagree with reality: neighbouring slots are sized as if the refusing window shrank, but it did not.

**Goal**: 300 ms after layout is applied, read back each window's actual AX size. For any window whose actual size differs from its slot target by more than 2 px, treat it as a refusal: adjust its slot fraction to match the actual size, re-run layout, and post a macOS notification naming the app.

---

## macOS notification note

`UNUserNotificationCenter` requires the app to have requested authorization before posting. For a menu-bar helper with no entitlement, the first call to `requestAuthorization` shows the system prompt once; subsequent calls are no-ops. `UNAuthorizationOptions.alert` is sufficient — no sound or badges needed.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/NotificationService.swift` | **New file** — thin `UNUserNotificationCenter` wrapper |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — call `NotificationService.shared.requestAuthorization()` in `init()` |
| `UnnamedWindowManager/Observation/PostResizeValidator.swift` | **New file** — `PostResizeValidator.checkAndFixRefusals(windows:screen:)` |
| `UnnamedWindowManager/Observation/ResizeObserver+Reapply.swift` | Modify — schedule refusal check 300 ms after resize reapply |

---

## Implementation Steps

### 1. NotificationService

New singleton that wraps `UNUserNotificationCenter`.

```swift
// Services/NotificationService.swift
import UserNotifications

final class NotificationService {
    static let shared = NotificationService()
    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
```

### 2. Request authorization at startup

In `UnnamedWindowManagerApp.init()`, after the existing `SharedRootStore.shared.initialize` call:

```swift
NotificationService.shared.requestAuthorization()
```

### 3. PostResizeValidator

New standalone type in `Observation/`, co-located with `ResizeObserver` since it runs immediately after the resize observation cycle completes. Accesses `ResizeObserver.shared` and `SnapService.shared` directly.

1. Reads the current leaf list (which carries the just-computed target `width`/`height` values).
2. Compares each window's actual AX size against the gap-adjusted target.
3. For any mismatch > 2 px, records the refusal and calls `SnapService.resize` to absorb the difference into fractions.
4. Re-runs `LayoutService.applyLayout` under a fresh `reapplying` guard.
5. Posts one notification per refusing window.

```swift
// Observation/PostResizeValidator.swift
import AppKit

enum PostResizeValidator {

    static func checkAndFixRefusals(windows: Set<WindowSlot>, screen: NSScreen) {
        struct Refusal {
            let key: WindowSlot
            let actual: CGSize
            let appName: String
        }

        let observer = ResizeObserver.shared
        var refusals: [Refusal] = []
        let leaves = SnapService.shared.allLeaves()

        for leaf in leaves {
            guard case .window(let w) = leaf, windows.contains(w) else { continue }
            guard let axEl = observer.elements[w], let actual = readSize(of: axEl) else { continue }

            let gap     = w.gaps ? Config.gap * 2 : 0
            let targetW = w.width  - gap
            let targetH = w.height - gap

            guard abs(actual.width - targetW) > 2 || abs(actual.height - targetH) > 2 else { continue }

            let appName = NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "Unknown"
            refusals.append(Refusal(key: w, actual: actual, appName: appName))
        }

        guard !refusals.isEmpty else { return }

        let allTracked = Set(leaves.compactMap { leaf -> WindowSlot? in
            if case .window(let w) = leaf { return w }
            return nil
        })
        observer.reapplying.formUnion(allTracked)

        for r in refusals {
            SnapService.shared.resize(key: r.key, actualSize: r.actual, screen: screen)
        }
        LayoutService.shared.applyLayout(screen: screen)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            observer.reapplying.subtract(allTracked)
        }

        for r in refusals {
            NotificationService.shared.post(
                title: "Window refused to resize",
                body: "\(r.appName) could not be resized to fit its slot."
            )
        }
    }
}
```

### 4. Schedule refusal check after resize reapply

In the `isResize` branch of `scheduleReapplyWhenMouseUp`, after the existing `reapplyAll` + 0.2 s clear, add:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
    guard let self, let screen = NSScreen.main else { return }
    PostResizeValidator.checkAndFixRefusals(windows: allWindows, screen: screen)
}
```

The `allWindows` capture is already computed just before `reapplyAll()` in the same `if isResize` block — no changes needed to how it is built. No `[weak self]` capture is required since `PostResizeValidator` is a stateless `enum`.

---

## Key Technical Notes

- `allLeaves()` is called inside `checkAndFixRefusals` AFTER `recomputeSizes` has already run (it ran inside `SnapService.resize` during the original resize). So `w.width` / `w.height` on each leaf reflect the target slot dimensions, not stale values.
- `SnapService.resize` accesses `store.queue.sync(flags: .barrier)`. It is called from the main thread via `DispatchQueue.main.asyncAfter` — `store.queue` is a separate serial queue so there is no deadlock.
- The second `LayoutService.applyLayout` call inside `checkAndFixRefusals` is guarded by `reapplying.formUnion(allTracked)`, preventing the resulting AX notifications from triggering a third resize cycle.
- Multiple refusals in one pass each get their own `SnapService.resize` call. Because `applyResize` chooses the axis with the larger delta, consecutive calls for independent windows are generally safe. Edge case: if two adjacent refusing windows both need adjusting, the second call may slightly shift the fractions set by the first; the final `applyLayout` will converge to a consistent state.
- Tolerance of 2 px accounts for CGFloat rounding across gap arithmetic. Tighter values may cause spurious refusals on some displays.
- `UNUserNotificationCenter.add` must be called from any thread — it is thread-safe. No special dispatch is required.

---

## Verification

1. Snap a terminal (e.g. Terminal.app or iTerm) and a second window side-by-side.
2. Drag the resize handle to make the terminal narrower than its minimum column width.
3. Release the mouse — the terminal snaps back to its minimum width.
4. Wait ~300 ms; a macOS notification appears: "Window refused to resize — Terminal could not be resized to fit its slot."
5. The neighbouring slot expands to fill the remaining space correctly.
6. Snap two normal windows and resize normally — no notification appears.
7. Quit and re-launch the app; no extra notification-permission prompt (authorization was already granted).
