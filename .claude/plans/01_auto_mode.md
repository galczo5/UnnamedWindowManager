# Plan: 01_auto_mode — Auto Mode: Auto-add new windows to active layout

## Checklist

- [x] Create `AutoModeService.swift` — singleton toggle for auto mode state
- [x] Create `WindowCreationObserver.swift` — AX observer for new window events
- [x] Add `ScrollHandler.scrollWindow(_:pid:)` — window-targeted scroll entry point
- [x] Create `AutoModeHandler.swift` — logic to route new window into tiling or scrolling root
- [x] Modify `UnnamedWindowManagerApp.swift` — add Auto mode toggle menu item, start observer, update `MenuState`

---

## Context / Problem

Currently, windows are added to tiling/scrolling layouts only when the user explicitly invokes "Tile", "Tile all", "Scroll", or "Scroll all" from the menu. If a new window opens while a layout is active, it is ignored.

Auto mode closes this gap: when the feature is enabled and a new window appears on a screen that already has an active tiling or scrolling root, the window is automatically added to that root — exactly as if the user had pressed "Tile" or "Scroll" from the menu.

---

## macOS capability note

`kAXWindowCreatedNotification` is registered on the **application** AX element but fires with the **new window** as the notification element. This means the AX callback receives the newly created `AXUIElement` directly — no enumeration needed. However, the window's frame may not be fully settled at callback time, so a short delay (0.2–0.3 s) before acting is required.

---

## Behaviour spec

- Auto mode state is **in-memory** (resets on relaunch) — same pattern as `WallpaperService.isActive`.
- When auto mode is **on**:
  - A new window appears → check the main screen for an active tiling or scrolling root.
  - If tiling root is active: snap the window in using `TileHandler.tileLeft(window:pid:)`.
  - If scrolling root is active: snap the window in using the new `ScrollHandler.scrollWindow(_:pid:)`.
  - If neither root is active: do nothing.
- Skip conditions (same as tile-all / scroll-all):
  - Window belongs to this process (own PID).
  - Window is already tracked by `ResizeObserver`.
  - Window is minimised.
  - Window is smaller than 100×100 pts.
- Menu label toggles between "Enable auto mode" / "Disable auto mode".
- Menu bar icon label gains `[auto]` indicator when auto mode is on and a root is active.

---

## Files to create / modify

| File | Action |
|------|--------|
| `Services/AutoMode/AutoModeService.swift` | **New file** — singleton bool toggle |
| `Services/Observation/WindowCreationObserver.swift` | **New file** — per-app `kAXWindowCreatedNotification` observer |
| `Services/AutoMode/AutoModeHandler.swift` | **New file** — decides tiling vs scrolling and applies |
| `Services/Handlers/ScrollHandler.swift` | Modify — add `scrollWindow(_:pid:)` entry point |
| `UnnamedWindowManagerApp.swift` | Modify — menu item, `MenuState.isAutoMode`, start observer |

---

## Implementation Steps

### 1. AutoModeService

Simple in-memory toggle. No persistence needed for v1.

```swift
// Holds the enabled/disabled state for auto mode.
final class AutoModeService {
    static let shared = AutoModeService()
    private init() {}

    var isEnabled: Bool = false

    func toggle() {
        isEnabled.toggle()
        NotificationCenter.default.post(name: .tileStateChanged, object: nil)
    }
}
```

---

### 2. ScrollHandler.scrollWindow(_:pid:)

Mirror of `TileHandler.tileLeft(window:pid:)` for scrolling. Add alongside the existing `scroll()` method in `ScrollHandler.swift`.

```swift
/// Adds `window` to the existing scrolling root, or creates a new one.
/// Skips if a tiling root is active, already tracked, minimised, or < 100×100 pts.
static func scrollWindow(_ window: AXUIElement, pid: pid_t) {
    guard AXIsProcessTrusted() else { return }
    guard TilingRootStore.shared.snapshotVisibleRoot() == nil else { return }
    guard let screen = NSScreen.main else { return }

    var minRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
       (minRef as? Bool) == true { return }
    if let sz = readSize(of: window), sz.width < 100 || sz.height < 100 { return }

    var key = windowSlot(for: window, pid: pid)
    key.preTileOrigin = readOrigin(of: window)
    key.preTileSize   = readSize(of: window)

    if ScrollingRootStore.shared.snapshotVisibleScrollingRoot() != nil {
        ScrollingRootStore.shared.addWindow(key, screen: screen)
    } else {
        ScrollingRootStore.shared.createScrollingRoot(key: key, screen: screen)
    }
    ResizeObserver.shared.observe(window: window, pid: pid, key: key)
    ReapplyHandler.reapplyAll()
}
```

---

### 3. AutoModeHandler

Routes a newly created window into whichever root type is currently active. Call this after the settle delay.

```swift
// Applies the active layout mode to a newly created window when auto mode is enabled.
struct AutoModeHandler {

    static func handleNewWindow(_ window: AXUIElement, pid: pid_t) {
        guard AutoModeService.shared.isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard pid != ownPID else { return }

        // Skip already-tracked windows.
        let key = windowSlot(for: window, pid: pid)
        guard !TilingRootStore.shared.isTracked(key) else { return }
        guard !ScrollingRootStore.shared.isTracked(key) else { return }

        if TilingRootStore.shared.snapshotVisibleRoot() != nil {
            TileHandler.tileLeft(window: window, pid: pid)
        } else if ScrollingRootStore.shared.snapshotVisibleScrollingRoot() != nil {
            ScrollHandler.scrollWindow(window, pid: pid)
        }
    }
}
```

---

### 4. WindowCreationObserver

Uses `AppObserverManager` to listen for `kAXWindowCreatedNotification` on each app that becomes active (same lifecycle as `FocusObserver`). The C callback dispatches to main with a settle delay before calling `AutoModeHandler`.

```swift
private func windowCreatedCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,   // the new window element
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let window = element
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        AutoModeHandler.handleNewWindow(window, pid: pid)
    }
}

// Observes kAXWindowCreatedNotification for every activated app and routes
// new windows into the active layout when auto mode is enabled.
final class WindowCreationObserver {
    static let shared = WindowCreationObserver()
    private init() {}

    private var observerManager: AppObserverManager?

    func start() {
        observerManager = AppObserverManager(
            callback: windowCreatedCallback,
            notifications: [kAXWindowCreatedNotification as CFString],
            refcon: Unmanaged.passUnretained(self).toOpaque())

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(didActivateApp(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(didTerminateApp(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // Observe already-running apps.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observerManager?.observeApp(pid: app.processIdentifier)
        }
    }

    @objc private func didActivateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        observerManager?.observeApp(pid: app.processIdentifier)
    }

    @objc private func didTerminateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        observerManager?.removeAppObserver(pid: app.processIdentifier)
    }
}
```

**Important**: Unlike `FocusObserver`, which only starts observing when an app is activated, `WindowCreationObserver.start()` also registers all currently-running regular apps at startup so auto mode works immediately even before switching apps.

---

### 5. Menu integration (UnnamedWindowManagerApp.swift)

Add `isAutoMode: Bool` to `MenuState` and a toggle button in the menu. Also update the menu bar label to include `[auto]` when auto mode is active.

In `MenuState.refresh()`:
```swift
var isAutoMode: Bool = false

func refresh() {
    // ... existing refresh code ...
    isAutoMode = AutoModeService.shared.isEnabled
}
```

Start `WindowCreationObserver` in `UnnamedWindowManagerApp.init()`:
```swift
WindowCreationObserver.shared.start()
```

Menu item (add after the wallpaper section, before the Divider before Reset layout):
```swift
Divider()
if menuState.isAutoMode {
    Button("Disable auto mode") { AutoModeService.shared.toggle(); menuState.refresh() }
} else {
    Button("Enable auto mode") { AutoModeService.shared.toggle(); menuState.refresh() }
}
```

Menu bar label — extend the label `HStack` to include `[auto]`:
```swift
if menuState.isAutoMode { Text("[auto]") }
```

---

## Key Technical Notes

- `kAXWindowCreatedNotification` fires with the new window as the `element` argument — no need to enumerate `kAXWindowsAttribute`.
- The 0.25 s delay in the callback is necessary: the window's position/size may not be readable immediately and `CGWindowList` won't yet include it.
- `AppObserverManager` registers the notification on the **application** AX element even though the callback receives a window element — this is the correct macOS AX pattern.
- `TileHandler.tileLeft` already guards against already-tracked, minimised, and small windows — the guard in `AutoModeHandler` before calling it is a cheap fast-path only.
- Call `PostResizeValidator.checkAndFixRefusals` after the layout settles, using the same 0.3 s delay pattern used elsewhere in the codebase (per MEMORY.md project rule).
- The `refcon` in `WindowCreationObserver`'s callback points to the observer itself, but the callback doesn't actually use it — `refcon` is required to be non-nil by the guard, so pass `Unmanaged.passUnretained(self).toOpaque()` for consistency with `FocusObserver`.

---

## Verification

1. Launch the app with no windows open → confirm "Enable auto mode" appears in menu.
2. Enable auto mode → label changes to "Disable auto mode"; menu bar icon gains `[auto]`.
3. Tile or scroll a window manually → layout root is active.
4. Open a new app window → after ~0.3 s it should snap into the active layout automatically.
5. Open a second new window → it should be added to the same root.
6. Disable auto mode → open another new window → it should NOT be auto-added.
7. With no active root, enable auto mode → open a window → nothing should happen.
8. Open a minimised window (un-minimise) → should NOT trigger auto-add (minimised check).
9. Quit and relaunch → auto mode should default to off (in-memory only).
10. Verify `PostResizeValidator.checkAndFixRefusals` fires after auto-added windows settle.
