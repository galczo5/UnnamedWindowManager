# Plan: 13_dim_inactive_windows — Dim Non-Focused Managed Windows

## Checklist

- [ ] Add `dimInactiveOpacity: CGFloat?` and `dimInactiveWindows: Bool?` to `ConfigData.BehaviorConfig`
- [ ] Add both fields to `ConfigData.defaults`, `missingKeys`, `mergedWithDefaults`
- [ ] Add `Config.dimInactiveOpacity` and `Config.dimInactiveWindows` static accessors
- [ ] Add both YAML entries to `ConfigLoader.format`
- [ ] Create `WindowOpacityService.swift` with private CGS bindings and dim/restore logic
- [ ] Create `FocusObserver.swift` that watches app activation and per-app focused-window changes
- [ ] Start `FocusObserver` in `UnnamedWindowManagerApp.init` (alongside `AutoSnapObserver`)
- [ ] Restore opacity in `UnsnapHandler` on unsnap and unsnapAll
- [ ] Restore opacity for a window in `ResizeObserver` when `kElementDestroyed` fires
- [ ] Call `WindowOpacityService.restoreAll()` on config reload when `dimInactiveWindows` is false

---

## Context / Problem

When the layout is active (windows are organized), all managed windows are visible on screen simultaneously. Users want non-focused windows visually dimmed so the active window stands out. Only managed windows (those in the snap tree) should be affected — unmanaged windows are never touched.

---

## macOS capability note

macOS exposes private CGS (CoreGraphics Server) APIs that set per-window opacity for any window, including those owned by other processes. The two functions needed:

```c
typedef int CGSConnection;
extern CGSConnection CGSMainConnectionID(void);
extern CGError CGSSetWindowAlpha(CGSConnection, CGWindowID, float);
```

These are accessed at runtime via `dlsym` — no App Store, no entitlements required. The `CGWindowID` is already available: `WindowSlot.windowHash` is the CGWindowID (confirmed by how `visibleRootID` uses `UInt(wid)` to populate `visibleHashes` and matches against `w.windowHash`).

---

## Behaviour spec

- Dimming applies **only when** `Config.dimInactiveWindows` is `true` and a visible layout root exists (i.e. `SnapService.shared.snapshotVisibleRoot() != nil`).
- When the focused window changes: set all managed windows except the focused one to `dimInactiveOpacity`; set the focused one to `1.0`.
- When the layout is destroyed or a window leaves the layout: restore that window's opacity to `1.0`.
- Non-managed windows are never touched.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/System/WindowOpacityService.swift` | **New file** — CGS bindings; `dim(focusedHash:)` and `restoreAll()` / `restore(hash:)` |
| `UnnamedWindowManager/Observation/FocusObserver.swift` | **New file** — NSWorkspace + AX notifications for focus changes |
| `UnnamedWindowManager/ConfigData.swift` | Modify — add `dimInactiveWindows` and `dimInactiveOpacity` to `BehaviorConfig` |
| `UnnamedWindowManager/Config.swift` | Modify — add `dimInactiveWindows` and `dimInactiveOpacity` static accessors |
| `UnnamedWindowManager/ConfigLoader.swift` | Modify — add YAML lines for both new fields |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — start `FocusObserver` in `init` |
| `UnnamedWindowManager/System/UnsnapHandler.swift` | Modify — restore opacity on unsnap / unsnapAll |
| `UnnamedWindowManager/Observation/ResizeObserver.swift` | Modify — restore opacity when `kElementDestroyed` fires |

---

## Implementation Steps

### 1. Config changes

Add to `ConfigData.BehaviorConfig`:
```swift
var dimInactiveWindows: Bool?
var dimInactiveOpacity: CGFloat?
```

Defaults: `dimInactiveWindows: true`, `dimInactiveOpacity: 0.8`. Update all three sites in `ConfigData`: `defaults`, `missingKeys`, `mergedWithDefaults`. Add to `Config`:
```swift
static var dimInactiveWindows: Bool    { shared.s.behavior!.dimInactiveWindows! }
static var dimInactiveOpacity: CGFloat { shared.s.behavior!.dimInactiveOpacity! }
```

Add to `ConfigLoader.format` inside the `behavior:` block:
```yaml
# Dim non-focused managed windows when a layout is active.
dimInactiveWindows: \(bh.dimInactiveWindows ?? true)
# Opacity of non-focused managed windows (0.0–1.0). Only used when dimInactiveWindows is true.
dimInactiveOpacity: \(num(bh.dimInactiveOpacity))
```

### 2. WindowOpacityService

Loads `CGSMainConnectionID` and `CGSSetWindowAlpha` via `dlsym` once at init. Exposes two operations:

```swift
// Applies dimInactiveOpacity to all managed windows except focusedHash, which gets 1.0.
// No-op if no visible layout root exists.
func dim(focusedHash: UInt)

// Restores opacity to 1.0 for a single window hash.
func restore(hash: UInt)

// Restores opacity to 1.0 for all currently managed windows.
func restoreAll()
```

Managed windows are collected via `SnapService.shared.leavesInVisibleRoot()`. Use `CGSSetWindowAlpha(connection, CGWindowID(hash), Float(opacity))`. Guard on `CGSSetWindowAlpha != nil` (dlsym may fail if the private API changes).

```swift
// Private CGS bindings loaded via dlsym
private typealias CGSSetWindowAlphaFn = @convention(c) (Int32, CGWindowID, Float) -> Int32
private typealias CGSMainConnectionIDFn = @convention(c) () -> Int32
```

### 3. FocusObserver

One AX observer per running app to catch `kAXFocusedWindowChangedNotification` (within-app window switches). Cross-app focus is covered by `NSWorkspace.didActivateApplicationNotification`.

```swift
final class FocusObserver {
    static let shared = FocusObserver()

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(didActivateApp(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(didTerminateApp(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        if let app = NSWorkspace.shared.frontmostApplication {
            observeApp(pid: app.processIdentifier)
            applyDimForFrontmostWindow(pid: app.processIdentifier)
        }
    }
}
```

On `didActivateApp`: register per-app AX observer for `kAXFocusedWindowChangedNotification`, then call `applyDimForFrontmostWindow(pid:)`.

`applyDimForFrontmostWindow(pid:)` queries `kAXFocusedWindowAttribute` on the app element, then matches the returned `AXUIElement` against `ResizeObserver.shared.elements` using `CFEqual` (same pattern used in `ResizeObserver.handle`). If a match is found, calls `WindowOpacityService.shared.dim(focusedHash: key.windowHash)`. If no match (unmanaged window focused), calls `restoreAll()`.

The C-compatible AX callback for `kAXFocusedWindowChangedNotification` follows the same pattern as `autoSnapCallback` in `AutoSnapObserver.swift`.

### 4. Restore on unsnap / window close

In `UnsnapHandler`, after removing a window from the layout, call `WindowOpacityService.shared.restore(hash: key.windowHash)`. After `unsnapAll`, call `WindowOpacityService.shared.restoreAll()`.

In `ResizeObserver.handle`, in the `kElementDestroyed` branch (before `cleanup`), call `WindowOpacityService.shared.restore(hash: key.windowHash)`.

---

## Key Technical Notes

- `CGSSetWindowAlpha` takes a `Float` (not `CGFloat`) and a `CGWindowID` (which is `UInt32`). Cast `windowHash` with `CGWindowID(hash)`.
- `dlsym(RTLD_DEFAULT, "CGSSetWindowAlpha")` — use `RTLD_DEFAULT` not a specific handle, since the symbol lives in the CoreGraphics private framework already loaded by the process.
- `kAXFocusedWindowChangedNotification` is sent to the **application element**, not the window. The callback receives the app element; query `kAXFocusedWindowAttribute` to get the currently focused window.
- When the focused window is unmanaged (not in the layout), `restoreAll()` is the correct action — don't leave managed windows permanently dimmed.
- All AX callbacks arrive on the main run loop; all CGS calls are safe from the main thread.
- Both `dimInactiveWindows` and `dimInactiveOpacity` are re-read on each `dim()` call since `Config` is always read live — no special reload handling needed.
- When `dimInactiveWindows` is toggled to `false` at runtime (config reload), `WindowOpacityService.restoreAll()` should be called from `ReapplyHandler.reapplyAll()` or equivalent so any currently-dimmed windows are immediately restored.

---

## Verification

1. Snap two or more windows into a layout → the non-focused window dims to 0.8 opacity.
2. Click the dimmed window → it becomes full opacity; the previously focused window dims.
3. Use focus direction shortcuts (ctrl+opt+arrow) → opacity updates to match new focused window.
4. Unsnap one window → its opacity is restored to 1.0 immediately.
5. Unsnap all → all windows are at full opacity.
6. Open an unmanaged window while layout is active → all managed windows restore to 1.0 (unmanaged window focused).
7. Switch back to a managed window → dimming resumes correctly.
8. Set `dimInactiveWindows: false` in config, reload → all managed windows restore to 1.0 immediately.
9. Set `dimInactiveOpacity: 0.5` in config, reload → non-focused windows dim to 0.5.
10. Layout with a single snapped window → no dimming (only window is the focused one).
