# Plan: 04_horizontal_resize — Per-Window Width & Resize Reflow

## Checklist

- [ ] Extend `SnapRegistry.swift` — store `width` and `height` alongside `slot`; add size-update helpers and bulk-read accessor
- [ ] Update `WindowSnapper.swift` — read original window size on snap; variable-width position math; `reapplyAll()` for reflow
- [ ] Update `ResizeObserver.swift` — on resize accept new size, update registry, trigger `reapplyAll()`; on move keep existing restore behavior

---

## Context

After 03_horizontal, every snapped window is forced to 40% of screen width. This plan makes widths dynamic:

- **Initial snap**: the window keeps its current width instead of being resized to 40%.
- **User resize**: the new width is accepted and stored; all other snapped windows shift left/right so no two windows overlap.
- **User move**: unchanged — the window is snapped back to its computed position (position guard stays in place).

---

## Files to modify

| File | Action |
|---|---|
| `UnnamedWindowManager/SnapRegistry.swift` | Modify — store `SnapEntry { slot, width, height }`; add `setSize`, `allEntries` |
| `UnnamedWindowManager/WindowSnapper.swift` | Modify — read original width on snap; variable-width X math; add `reapplyAll()` |
| `UnnamedWindowManager/ResizeObserver.swift` | Modify — split move vs. resize handling; resize path updates width and calls `reapplyAll()` |

---

## Implementation Steps

### 1. `SnapRegistry` — store width and height per window

Replace the `[SnapKey: Int]` store with a `[SnapKey: SnapEntry]` store:

```swift
struct SnapEntry {
    let slot: Int
    var width: CGFloat
    var height: CGFloat
}

final class SnapRegistry {
    private var store: [SnapKey: SnapEntry] = [:]
    private let queue = DispatchQueue(label: "snap.registry", attributes: .concurrent)

    func register(_ key: SnapKey, slot: Int, width: CGFloat, height: CGFloat) {
        queue.async(flags: .barrier) {
            self.store[key] = SnapEntry(slot: slot, width: width, height: height)
        }
    }

    func entry(for key: SnapKey) -> SnapEntry? {
        queue.sync { store[key] }
    }

    func setSize(width: CGFloat, height: CGFloat, for key: SnapKey) {
        queue.async(flags: .barrier) {
            self.store[key]?.width = width
            self.store[key]?.height = height
        }
    }

    /// Returns a snapshot of all entries sorted ascending by slot.
    func allEntries() -> [(key: SnapKey, entry: SnapEntry)] {
        queue.sync {
            store.map { (key: $0.key, entry: $0.value) }
                 .sorted { $0.entry.slot < $1.entry.slot }
        }
    }

    func nextSlot() -> Int {
        queue.sync { (store.values.map(\.slot).max() ?? -1) + 1 }
    }

    func remove(_ key: SnapKey) {
        queue.async(flags: .barrier) { self.store.removeValue(forKey: key) }
    }

    func isTracked(_ key: SnapKey) -> Bool {
        entry(for: key) != nil
    }
}
```

`slot(for:)` is replaced by `entry(for:)`. `nextSlot()` reads `.slot` from each entry.

---

### 2. Read the original window size on snap

In `WindowSnapper.snap()`, before registering, read the current window size via AX:

```swift
static func snap() {
    // … AX trust check, get frontApp, axWindow …

    let visible = NSScreen.main?.visibleFrame ?? .zero
    let gap: CGFloat = 10
    let snapHeight   = visible.height - gap * 2          // always full visible height on first snap
    let originalWidth = readSize(of: axWindow)?.width ?? visible.width * 0.4

    let key  = snapKey(for: axWindow, pid: pid)
    let slot = SnapRegistry.shared.nextSlot()

    SnapRegistry.shared.register(key, slot: slot, width: originalWidth, height: snapHeight)
    applyPosition(to: axWindow, key: key)
    ResizeObserver.shared.observe(window: axWindow, pid: pid, key: key)
}

internal static func readSize(of window: AXUIElement) -> CGSize? {
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let axVal = sizeRef,
          CFGetTypeID(axVal) == AXValueGetTypeID()
    else { return nil }
    var size = CGSize.zero
    AXValueGetValue(axVal as! AXValue, .cgSize, &size)
    return (size.width > 0 && size.height > 0) ? size : nil
}
```

On initial snap the window is **not resized** — only its X/Y position is set. Both dimensions are stored for future use.

---

### 3. Variable-width position math

Position windows left-to-right in slot order, each separated by a gap. The X offset for a given window is the sum of widths and gaps of all windows in lower slots.

```swift
static func reapplyAll() {
    guard let screen = NSScreen.main else { return }
    let entries = SnapRegistry.shared.allEntries()

    for (key, _) in entries {
        // Resolve AXUIElement from key — ResizeObserver keeps a window map
        guard let axWindow = ResizeObserver.shared.window(for: key) else { continue }
        applyPosition(to: axWindow, key: key, entries: entries, screen: screen)
    }
}

static func reapply(window: AXUIElement, key: SnapKey) {
    guard SnapRegistry.shared.entry(for: key) != nil else { return }
    let entries = SnapRegistry.shared.allEntries()
    applyPosition(to: window, key: key, entries: entries, screen: NSScreen.main)
}

private static func applyPosition(
    to window: AXUIElement,
    key: SnapKey,
    entries: [(key: SnapKey, entry: SnapEntry)]? = nil,
    screen: NSScreen? = NSScreen.main
) {
    guard let screen else { return }
    let visible = screen.visibleFrame
    let primaryHeight = NSScreen.screens[0].frame.height
    let gap: CGFloat = 10

    let allEntries = entries ?? SnapRegistry.shared.allEntries()
    guard let myEntry = allEntries.first(where: { $0.key == key })?.entry else { return }

    // Sum widths of all windows in slots before this one
    var xOffset = visible.minX + gap
    for item in allEntries {
        if item.entry.slot == myEntry.slot { break }
        xOffset += item.entry.width + gap
    }

    let axY = primaryHeight - visible.maxY + gap

    var origin = CGPoint(x: xOffset, y: axY)
    var size   = CGSize(width: myEntry.width, height: myEntry.height)

    if let posVal = AXValueCreate(.cgPoint, &origin) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
    }
    if let sizeVal = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
    }
}
```

---

### 4. `ResizeObserver` — split move vs. resize

Currently the observer calls `WindowSnapper.reapply` for both move and resize notifications. Split them:

- **`kAXWindowMovedNotification`**: call `WindowSnapper.reapply(window:key:)` — restores position (position guard, unchanged behavior).
- **`kAXWindowResizedNotification`**: read the new size from the window, call `SnapRegistry.shared.setSize(_:for:)`, then call `WindowSnapper.reapplyAll()` — this repositions all windows without reverting their sizes.

```swift
// Inside the AX callback:
if notification == kAXWindowResizedNotification {
    if let newSize = WindowSnapper.readSize(of: axWindow) {
        SnapRegistry.shared.setSize(width: newSize.width, height: newSize.height, for: key)
    }
    WindowSnapper.reapplyAll()
} else {
    // kAXWindowMovedNotification
    WindowSnapper.reapply(window: axWindow, key: key)
}
```

`ResizeObserver` must store a `[SnapKey: AXUIElement]` map so `reapplyAll()` can look up windows by key. Add:

```swift
private var windowMap: [SnapKey: AXUIElement] = [:]

func observe(window: AXUIElement, pid: pid_t, key: SnapKey) {
    windowMap[key] = window
    // … existing observer setup …
}

func window(for key: SnapKey) -> AXUIElement? {
    windowMap[key]
}

func stopObserving(key: SnapKey, pid: pid_t) {
    windowMap.removeValue(forKey: key)
    // … existing teardown …
}
```

The in-flight / debounce guard already prevents infinite reapply loops. The same guard covers `reapplyAll()` — mark all keys as in-flight before applying, clear after.

---

## Key Technical Notes

- **No resize on snap**: the window's current width and height are both preserved on first snap. Only position (X, Y) is changed.
- **Resize acceptance**: the resize notification fires after the user finishes dragging. Both the new width and height are read once, stored, and the full column is reflowed. Neither dimension is overridden.
- **Slot order = visual order**: windows are laid out left-to-right in ascending slot order, so the first snapped window is always leftmost.
- **Gaps between removed slots**: slots from unsnapped windows are skipped in `allEntries()` (they're removed from the store), so there are no phantom gaps.
- **`readSize` visibility**: `internal` (not `private`) so `ResizeObserver` can call it without duplicating the AX read logic.
- **Window map thread safety**: access `windowMap` on the same `DispatchQueue` used for registry reads, or under a separate lock, to avoid data races in the AX callback.
- **Debounce scope for reapplyAll**: when `reapplyAll()` fires, it sets all currently-tracked keys as in-flight. Each per-window reapply triggers a moved notification that is suppressed by the in-flight guard.

---

## Verification

1. Open Finder (800×600). Click **Snap Right** → Finder moves to leftmost position, keeps its 800 px width and 600 px height.
2. Open Safari (600×400). Click **Snap Right** → Safari appears immediately to the right of Finder (gap 10 px), keeps its 600×400 size.
3. Resize Finder to 500 px wide → Safari shifts left; no overlap. Finder's height updates too.
4. Resize Safari taller → height stored; width of other windows unaffected.
5. Drag Finder away → Finder snaps back to its computed X position.
6. Click **Unsnap** with Safari focused → Safari can move freely; Finder stays tracked.
7. Open Terminal. Click **Snap Right** → Terminal appears to the right of Safari (or Finder if Safari is unsnapped).
