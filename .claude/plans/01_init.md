# Plan: 01_init — Menu Bar Window Snapper PoC

## Checklist

- [x] Disable App Sandbox in `.entitlements`
- [x] Add `LSUIElement = YES` to `Info.plist`
- [x] Replace `WindowGroup` with `MenuBarExtra` in `UnnamedWindowManagerApp.swift`
- [x] Create `WindowSnapper.swift` with Accessibility-based snap logic
- [x] Delete `ContentView.swift`

---

## Context

The project is a brand-new macOS SwiftUI app (Xcode scaffold, no real code yet). The goal is a lightweight PoC that lives in the macOS menu bar, shows "Snap Left" and "Snap Right" actions, and resizes/repositions the currently active window accordingly.

- **Snap Right** → x = 60% of screen width, y = 0 (top of visible area), width = 40% screen width, height = 100% visible screen height
- **Snap Left**  → x = 0, y = 0, width = 40% screen width, height = 100% visible screen height

Screen dimensions use `NSScreen.main?.visibleFrame` (excludes menu bar + Dock) — the most natural interpretation of "100% height" for a window manager.

---

## Files to create / modify

| File | Action |
|---|---|
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — replace `WindowGroup` with `MenuBarExtra`, hide dock icon |
| `UnnamedWindowManager/WindowSnapper.swift` | Create — Accessibility-based window resize/reposition logic |
| `UnnamedWindowManager/Info.plist` | Create/modify — add `LSUIElement = YES` |
| `UnnamedWindowManager/UnnamedWindowManager.entitlements` | Modify — disable App Sandbox for PoC |
| `UnnamedWindowManager/ContentView.swift` | Delete — no longer needed |

---

## Implementation Steps

### 1. Disable App Sandbox (PoC)

In the `.entitlements` file, set `com.apple.security.app-sandbox` to `NO`.
Accessibility APIs (`AXUIElement`) require either sandbox exceptions or no sandbox. Removing it is the simplest path for a PoC.

### 2. Hide the Dock icon

Add `LSUIElement` key (`Boolean`, `YES`) to `Info.plist`. This prevents the app from appearing in the Dock and ⌘-Tab switcher — standard practice for menu bar utilities.

### 3. Convert app entry point to a menu bar app

Replace the `WindowGroup` scene in `UnnamedWindowManagerApp.swift` with `MenuBarExtra` (macOS 13+):

```swift
@main
struct UnnamedWindowManagerApp: App {
    var body: some Scene {
        MenuBarExtra("Window Manager", systemImage: "rectangle.split.2x1") {
            Button("Snap Left")  { WindowSnapper.snap(.left)  }
            Button("Snap Right") { WindowSnapper.snap(.right) }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
```

Deployment target must be **macOS 13.0+**.

### 4. Implement `WindowSnapper`

New file `WindowSnapper.swift` using the macOS Accessibility APIs (`ApplicationServices`):

**Logic:**
1. Check `AXIsProcessTrusted()` — if not granted, call `AXIsProcessTrustedWithOptions` to trigger the system permission prompt, then return early.
2. Get `NSWorkspace.shared.frontmostApplication` and create an `AXUIElementCreateApplication` from its PID.
3. Read `kAXFocusedWindowAttribute` to get the target window.
4. Compute the target frame from `NSScreen.main!.visibleFrame` (40% width, full visible height, left or right aligned).
5. **Coordinate conversion**: AX APIs use a flipped coordinate system (top-left origin). Convert with: `axY = NSScreen.screens[0].frame.height - visibleFrame.maxY`.
6. Call `AXUIElementSetAttributeValue` with `kAXPositionAttribute` first, then `kAXSizeAttribute` (order matters to avoid animation artifacts).

---

## Key Technical Notes

- `MenuBarExtra` requires macOS 13 (Ventura)+.
- AX position uses **flipped coordinates** (top-left origin) while AppKit uses bottom-left. The `y` conversion is: `axY = totalScreenHeight - visibleFrame.maxY`.
- Set **position before size** to avoid layout glitches.
- On first run with no Accessibility permission, the snap silently shows the system prompt; subsequent clicks will work.

---

## Verification

1. Build & run from Xcode — a rectangle icon appears in the menu bar; no Dock icon.
2. Open any window (Finder, Safari, Terminal).
3. Click the menu bar icon → **Snap Right** → window resizes to 40% width, snaps to right edge.
4. Click **Snap Left** → window moves to 40% width on the left edge.
5. On first run, macOS shows the Accessibility permission prompt (System Settings → Privacy & Security → Accessibility). Grant it, re-click to confirm it works.
