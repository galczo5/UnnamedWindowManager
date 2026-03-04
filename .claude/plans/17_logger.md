# Plan: 17_logger — Add file-backed logger with configurable path

## Checklist

- [ ] Add `logFilePath` to `Config.swift`
- [ ] Create `Logger.swift` with `Logger` singleton
- [ ] Replace `print` calls across the codebase with `Logger.log`
- [ ] Log AX resize/move notifications in `ResizeObserver.handle()`
- [ ] Log programmatic position+size writes in `WindowSnapper.applyPosition()`
- [ ] Log offset changes in `CurrentOffset.setOffset()`
- [ ] Log focus/activation of managed windows in `WindowEventMonitor.handleFocusChanged()`
- [ ] Log app start with timestamp in `UnnamedWindowManagerApp.init()`

---

## Context / Problem

Debugging the window manager currently relies on `print` statements scattered across the codebase, which are only visible when the app is launched from Xcode or a terminal. When the app runs as a normal macOS agent (launched at login, from the menu bar, etc.) there is no way to inspect what happened after the fact.

**Goal:** a lightweight `Logger` singleton that appends timestamped lines to a log file (`~/.unnamed.log` by default). The path is configurable via `Config.logFilePath`. Existing `print` calls are migrated to `Logger.log`, and three key event streams get dedicated log lines: window resizes, position changes, and scroll offset changes.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Config.swift` | Modify — add `logFilePath` constant |
| `UnnamedWindowManager/Logger.swift` | **New file** — `Logger` singleton |
| `UnnamedWindowManager/Observation/ResizeObserver.swift` | Modify — log AX resize/move notifications |
| `UnnamedWindowManager/Snapping/SnapLayout.swift` | Modify — log computed origin+size in `applyPosition` |
| `UnnamedWindowManager/Model/CurrentOffset.swift` | Modify — log old→new offset in `setOffset` |
| `UnnamedWindowManager/Observation/WindowEventMonitor.swift` | Modify — log focus/activation of managed windows |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — log app start with timestamp |

---

## Implementation Steps

### 1. Add `logFilePath` to `Config`

Append one constant to the `Config` enum. Using `NSHomeDirectory()` keeps it sandboxing-safe and human-readable.

```swift
/// Absolute path of the log file written by Logger.
static let logFilePath: String = NSHomeDirectory() + "/.unnamed.log"
```

### 2. Create `Logger.swift`

The logger must be:
- **Thread-safe** — AX callbacks and the main thread can both call `log` concurrently.
- **Append-only** — opens the file with `O_WRONLY | O_CREAT | O_APPEND` so existing entries survive restarts.
- **Non-blocking for callers** — writes are dispatched onto a private serial queue.

```swift
import Foundation

final class Logger {
    static let shared = Logger()

    private let queue = DispatchQueue(label: "com.unnamed.logger", qos: .utility)
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private var fileHandle: FileHandle?

    private init() {
        let path = Config.logFilePath
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: path)
        fileHandle?.seekToEndOfFile()
    }

    func log(_ message: String, file: String = #file, function: String = #function) {
        let timestamp = formatter.string(from: Date())
        let filename = URL(fileURLWithPath: file).lastPathComponent
        let line = "[\(timestamp)] [\(filename)] \(function): \(message)\n"
        queue.async { [weak self] in
            guard let data = line.data(using: .utf8) else { return }
            self?.fileHandle?.write(data)
        }
    }
}
```

### 3. Replace existing `print` calls

For each existing `print(…)` call site (currently only in `ResizeObserver+Reapply.verifyWidthsAfterResize`), replace with `Logger.shared.log(…)`.

```swift
// Before
print("[WidthVerify] \"\(title)\": stored=\(slot.width) actual=\(actualWidth)")

// After
Logger.shared.log("[WidthVerify] \"\(title)\": stored=\(slot.width) actual=\(actualWidth)")
```

### 4. Log resize and move notifications in `ResizeObserver.handle()`

At the top of `handle(element:notification:pid:)`, after the `key` is resolved, add one log line so every inbound AX event is recorded:

```swift
let eventLabel = notification == kAXWindowResizedNotification as String ? "resize" : "move"
Logger.shared.log("[\(eventLabel)] key=\(key.windowHash) pid=\(pid)")
```

This fires for both user-initiated drags/resizes and any other source. The `reapplying` guard further down will suppress reapply for our own programmatic moves, but the notification itself is still worth recording.

### 5. Log programmatic position and size writes in `applyPosition`

In `WindowSnapper.applyPosition(to:key:slots:)`, after `origin` and `size` are computed and before the AX calls, add:

```swift
Logger.shared.log("applyPosition key=\(key.windowHash) origin=(\(Int(origin.x)),\(Int(origin.y))) size=(\(Int(size.width))×\(Int(size.height)))")
```

This records every frame the window manager writes to a window, covering both `reapply` and `reapplyAll` paths.

### 6. Log offset changes in `CurrentOffset.setOffset()`

In `setOffset(_:)`, log the transition before clamping so both the requested and the effective value are visible:

```swift
func setOffset(_ newValue: Int) {
    let clamped = max(0, newValue)
    Logger.shared.log("offset \(value) → \(clamped)")
    value = clamped
    suppressFocusScroll(for: 0.6)
    WindowSnapper.reapplyAll()
}
```

### 7. Log app start in `UnnamedWindowManagerApp.init()`

Add a single log line at the top of `init()`, after `Logger` is first used. The timestamp is already embedded in every log line by the logger, so just emit a clear separator:

```swift
init() {
    Logger.shared.log("=== UnnamedWindowManager started ===")
    WindowEventMonitor.shared.start()
}
```

This makes it easy to find session boundaries when tailing the log file.

### 8. Log focus and activation of managed windows in `handleFocusChanged`

`handleFocusChanged(axWindow:)` in `WindowEventMonitor` is the single choke point for all focus events — both app activations (via `appActivated`) and in-app window switches (via `appNotificationCallback`). After the key and slot index are successfully resolved, read the window title, the actual frame from AX, compute the expected frame using the same formula as `applyPosition`, and log all of it.

```swift
func handleFocusChanged(axWindow: AXUIElement) {
    guard !CurrentOffset.shared.isSuppressingFocusScroll else { return }
    guard let key = ResizeObserver.shared.elements.first(where: {
        CFEqual($0.value, axWindow)
    })?.key else { return }
    guard let slotIndex = ManagedSlotRegistry.shared.slotIndex(for: key) else { return }

    // --- logging ---
    var titleRef: CFTypeRef?
    let title = AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success
        ? (titleRef as? String ?? "<unknown>") : "<unknown>"

    var actualOrigin = CGPoint.zero
    var actualSize   = CGSize.zero
    if let screen = NSScreen.main {
        let primaryH = NSScreen.screens[0].frame.height
        if var posVal = AXValueCreate(.cgPoint, &actualOrigin),
           AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posVal) == .success {
            AXValueGetValue(posVal as! AXValue, .cgPoint, &actualOrigin)
        }
        if var sizeVal = AXValueCreate(.cgSize, &actualSize),
           AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeVal) == .success {
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &actualSize)
        }

        let slots   = ManagedSlotRegistry.shared.allSlots()
        let visible = screen.visibleFrame
        var calcX   = visible.minX + Config.gap - CGFloat(CurrentOffset.shared.value)
        for i in 0..<slotIndex { calcX += slots[i].width + Config.gap }
        let calcY   = primaryH - visible.maxY + Config.gap

        Logger.shared.log(
            "[focus] id=\(key.windowHash) name=\"\(title)\" slot=\(slotIndex)" +
            " calc=(\(Int(calcX)),\(Int(calcY)))" +
            " actual=(\(Int(actualOrigin.x)),\(Int(actualOrigin.y)))" +
            " size=(\(Int(actualSize.width))×\(Int(actualSize.height)))"
        )
    }
    // --- end logging ---

    CurrentOffset.shared.scheduleOffsetUpdate(forSlot: slotIndex)
}
```

The calculated Y is the top of the slot (first window's AX origin Y); windows below the first in the same slot will have a different actual Y, but the slot position is what matters for focus scrolling.

---

## Key Technical Notes

- `FileHandle.write(_:)` is not thread-safe; all writes are serialised on the private `DispatchQueue`.
- `ISO8601DateFormatter` is expensive to allocate; hoist it to a stored property (done above).
- The file is never rotated or truncated; the user can delete `~/.unnamed.log` manually.
- `#file` expands to the full source path at compile time; `URL.lastPathComponent` trims it to the filename only.
- No Sandbox entitlement is needed for writing to `~` when the app runs as an agent without App Sandbox.
- `applyPosition` is called for every window on every `reapplyAll` — log volume can be high when many windows are snapped. This is intentional for debugging; can be gated behind a flag later if needed.
- The `handle()` log fires before the `reapplying` guard, so it records AX notifications caused by our own programmatic moves. The `reapplying` guard will still suppress the resulting reapply; the log entry is still useful to see that the notification arrived.
- The focus log reads AX position/size at the moment focus changes, which is before any scroll reapply — so the actual position reflects where the window was, not where it will be moved to.
- Calculated X uses `slotIndex` and the current offset; it represents slot 0 of each slot's column (vertical stacks will all share the same X).
- `AXValueCreate` + immediate `AXUIElementCopyAttributeValue` pattern: the `AXValue` passed into Copy must be the right type tag — use `.cgPoint` for position and `.cgSize` for size.

---

## Verification

1. Build and launch the app from Xcode → `~/.unnamed.log` is created automatically.
2. Snap a window → log contains `applyPosition` entries with origin and size.
3. Drag a snapped window → log contains `[move]` notification, then `applyPosition` restoring it.
4. Resize a snapped window → log contains `[resize]` notification, then `applyPosition` entries for all windows after reflow.
5. Press Scroll Left / Scroll Right → log contains `offset N → M` line.
6. Quit and relaunch → new entries are appended; old entries are preserved.
7. Launch the app from Finder (not Xcode) → log file still receives entries.
8. Launch the app → log contains `=== UnnamedWindowManager started ===` with a timestamp.
9. Switch between two snapped windows → each switch produces a `[focus]` line with the window name, slot index, calculated position, and actual position.
10. Activate an unmanaged window → no `[focus]` line (guard exits early because the key is not tracked).
