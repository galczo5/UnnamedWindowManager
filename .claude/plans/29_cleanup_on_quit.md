# Plan: 29_cleanup_on_quit — Untile/Unscroll All Roots on App Quit

## Checklist

- [ ] Add `removeAllTilingRoots()` to `TileService`
- [ ] Add `removeAllScrollingRoots()` to `ScrollingTileService`
- [ ] Add `UntileHandler.untileAllSpaces()` using `removeAllTilingRoots()`
- [ ] Add `UnscrollHandler.unscrollAllSpaces()` using `removeAllScrollingRoots()`
- [ ] Create `AppDelegate.swift` with `applicationWillTerminate` cleanup
- [ ] Wire `AppDelegate` into `UnnamedWindowManagerApp` via `@NSApplicationDelegateAdaptor`

---

## Context / Problem

`UntileHandler.untileAll()` and `UnscrollHandler.unscrollAll()` only operate on the "visible" root — the one that has at least one window currently on screen in the active Space. If the user has tiled/scrolled windows on another Space (or the Space is not currently displayed), those roots are not cleaned up.

On quit the app should restore every tiled/scrolled window in every root, regardless of Space visibility, so that other apps' windows are left in their original positions.

---

## macOS capability note

The Accessibility API (`AXUIElementSetAttributeValue`) works on windows belonging to any app, even if those windows are on a non-active Space. The window manager can safely restore position/size and un-minimize windows that are not currently visible on screen.

---

## Behaviour spec

When the app terminates (any termination path — Quit menu item, Cmd+Q, Activity Monitor, `kill`):
1. Every window in every tiling root is removed and its pre-tile frame is restored.
2. Every window in every scrolling root is removed and its pre-tile frame is restored.
3. Any auto-minimized window is un-minimized.
4. Window opacity is restored.
5. No layout reapply or state notifications are posted (app is exiting).

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/TileService.swift` | Modify — add `removeAllTilingRoots()` |
| `UnnamedWindowManager/Services/ScrollingTileService.swift` | Modify — add `removeAllScrollingRoots()` |
| `UnnamedWindowManager/System/UntileHandler.swift` | Modify — add `untileAllSpaces()` |
| `UnnamedWindowManager/System/UnscrollHandler.swift` | Modify — add `unscrollAllSpaces()` |
| `UnnamedWindowManager/AppDelegate.swift` | **New file** — `NSApplicationDelegate` with `applicationWillTerminate` |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — add `@NSApplicationDelegateAdaptor` |

---

## Implementation Steps

### 1. Add `removeAllTilingRoots()` to `TileService`

Iterates every root in `store.roots`, collects leaves from all `.tiling` roots, clears them, and returns the full `[WindowSlot]` list.

```swift
func removeAllTilingRoots() -> [WindowSlot] {
    return store.queue.sync(flags: .barrier) {
        let tilingIDs = store.roots.keys.filter {
            if case .tiling = store.roots[$0]! { return true }
            return false
        }
        var all: [WindowSlot] = []
        for id in tilingIDs {
            guard case .tiling(let root) = store.roots[id] else { continue }
            all += treeQuery.allLeaves(in: root).compactMap {
                if case .window(let w) = $0 { return w } else { return nil }
            }
            store.roots.removeValue(forKey: id)
            store.windowCounts.removeValue(forKey: id)
        }
        return all
    }
}
```

### 2. Add `removeAllScrollingRoots()` to `ScrollingTileService`

Same pattern, filtering `.scrolling` roots and using the existing private `allWindowSlots(in:)` helper.

```swift
func removeAllScrollingRoots() -> [WindowSlot] {
    return store.queue.sync(flags: .barrier) {
        let scrollingIDs = store.roots.keys.filter {
            if case .scrolling = store.roots[$0]! { return true }
            return false
        }
        var all: [WindowSlot] = []
        for id in scrollingIDs {
            guard case .scrolling(let root) = store.roots[id] else { continue }
            all += allWindowSlots(in: root)
            store.roots.removeValue(forKey: id)
            store.windowCounts.removeValue(forKey: id)
        }
        return all
    }
}
```

### 3. Add `UntileHandler.untileAllSpaces()`

Mirrors `untileAll()` but calls `removeAllTilingRoots()` instead of `removeVisibleRoot()`. Skips `ReapplyHandler` and notifications since the app is quitting.

```swift
static func untileAllSpaces() {
    guard AXIsProcessTrusted() else { return }
    let elements = ResizeObserver.shared.elements
    let removed = TileService.shared.removeAllTilingRoots()
    WindowOpacityService.shared.restoreAll()
    for key in removed {
        if let ax = elements[key] { RestoreService.restore(key, element: ax) }
        WindowVisibilityManager.shared.restoreAndForget(key)
        ResizeObserver.shared.stopObserving(key: key, pid: key.pid)
    }
}
```

### 4. Add `UnscrollHandler.unscrollAllSpaces()`

Same as `unscrollAll()` but calls `removeAllScrollingRoots()`.

```swift
static func unscrollAllSpaces() {
    guard AXIsProcessTrusted() else { return }
    let elements = ResizeObserver.shared.elements
    let removed = ScrollingTileService.shared.removeAllScrollingRoots()
    WindowOpacityService.shared.restoreAll()
    for key in removed {
        if let ax = elements[key] { RestoreService.restore(key, element: ax) }
        WindowVisibilityManager.shared.restoreAndForget(key)
        ResizeObserver.shared.stopObserving(key: key, pid: key.pid)
    }
}
```

### 5. Create `AppDelegate.swift`

```swift
import AppKit

// NSApplicationDelegate that cleans up all tiled and scrolled windows before the app exits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        UntileHandler.untileAllSpaces()
        UnscrollHandler.unscrollAllSpaces()
    }
}
```

### 6. Wire `AppDelegate` into `UnnamedWindowManagerApp`

Add the adaptor property to `UnnamedWindowManagerApp`:

```swift
@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
```

Place it as the first stored property inside `UnnamedWindowManagerApp`, before `@State private var menuState`.

---

## Key Technical Notes

- `removeVisibleRoot()` / `removeVisibleScrollingRoot()` use `OnScreenWindowCache.visibleHashes()` to find windows on screen — this misses windows on inactive Spaces. The new `removeAll*` methods skip that check entirely.
- `applicationWillTerminate` is synchronous; AX attribute writes are synchronous too, so frame restoration completes before the process exits.
- `WindowOpacityService.shared.restoreAll()` is called once and covers both tiling and scrolling windows — calling it twice (once per handler) is safe because the second call is a no-op after all opacity states are cleared.
- Do NOT call `ReapplyHandler.reapplyAll()` in the termination path — the app is exiting and there is nothing to reapply.
- `@NSApplicationDelegateAdaptor` is the correct SwiftUI hook for `NSApplicationDelegate`. It integrates cleanly with the existing `App`-protocol entry point without requiring an `UIApplicationMain`-style replacement.

---

## Verification

1. Tile several windows → switch to a different Space → tile more windows in the new Space → quit the app → confirm all windows on both Spaces are restored to their original positions.
2. Scroll several windows → switch Space → scroll more windows → quit → confirm all windows unscrolled and at original positions.
3. Mix tiled and scrolled windows across two Spaces → quit → all restored.
4. Quit with no tiled/scrolled windows → no crash, no error.
5. Quit via Cmd+Q (not the menu item) → same cleanup occurs.
