# Plan: 22_scroll_auto_center_on_focus — Auto-scroll focused window to center slot

## Checklist

- [ ] Add `ScrollingSlotLocation` enum and `location(of:)` helper to ScrollingTileService
- [ ] Add `scrollToWindow(_:screen:)` batch method to ScrollingTileService
- [ ] Add `scrollToCenter(key:)` to ScrollingFocusService
- [ ] Hook auto-center into FocusObserver.applyDim

---

## Context / Problem

When a window inside a scroll root receives focus (e.g. the user clicks a partially-visible side window or Cmd-Tabs to an app whose window lives in a side slot), it stays in its current slot. The user must manually press Focus Right / Focus Left repeatedly to bring it to center.

**Goal:** When a non-center window in a scroll root receives OS focus, automatically scroll the root so that window ends up in the center slot — equivalent to pressing focus-right or focus-left the correct number of times.

---

## Behaviour spec

- A window already in center → no-op.
- A window in the right stacking slot at index `i` (0-based from start, last element closest to center) → scroll right `count - i` times.
- A window in the left stacking slot at index `i` → scroll left `count - i` times.
- Scrolling is batched into a single data mutation + single layout apply (no intermediate frames).
- After scrolling, the window is activated and dimming is applied with the new center hash.
- Focus changes triggered by the auto-scroll itself (the `activateAfterLayout` call) must not cause re-entrant scrolling. This is safe because after scrolling, the focused window IS the center → `location(of:)` returns `.center` → no-op.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/Scrolling/ScrollingTileService.swift` | Modify — add `ScrollingSlotLocation` enum, `location(of:)`, `scrollToWindow(_:screen:)` |
| `UnnamedWindowManager/Services/Scrolling/ScrollingFocusService.swift` | Modify — add `scrollToCenter(key:)` |
| `UnnamedWindowManager/Services/Observation/FocusObserver.swift` | Modify — call auto-center from `applyDim` |

---

## Implementation Steps

### 1. Add location detection to ScrollingTileService

Add a `ScrollingSlotLocation` enum and a public method that determines which slot a window occupies.

```swift
enum ScrollingSlotLocation {
    case center
    case left(index: Int, count: Int)   // index in children array, count = children.count
    case right(index: Int, count: Int)
}
```

```swift
func location(of key: WindowSlot) -> ScrollingSlotLocation? {
    store.queue.sync {
        guard let id = visibleScrollingRootID(),
              case .scrolling(let root) = store.roots[id] else { return nil }
        return location(of: key, in: root)
    }
}

private func location(of key: WindowSlot, in root: ScrollingRootSlot) -> ScrollingSlotLocation? {
    if isCenterWindow(key, in: root) { return .center }
    if case .stacking(let s) = root.left,
       let idx = s.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
        return .left(index: idx, count: s.children.count)
    }
    if case .stacking(let s) = root.right,
       let idx = s.children.firstIndex(where: { $0.windowHash == key.windowHash }) {
        return .right(index: idx, count: s.children.count)
    }
    return nil
}
```

### 2. Add batch scroll method to ScrollingTileService

Add `scrollToWindow(_:screen:)` that performs the equivalent of N scroll operations in a single store mutation. Returns the new center `WindowSlot`, or nil if nothing to do.

The stacking slot order convention: last element is closest to center (removed first by `scrollRight`/`scrollLeft`).

**Right-scroll batch** (target at index `i` in right stack of count `n`, needs `n - i` scrolls):
1. Remove elements from index `i` onward from right stack: `[target, i+1, i+2, …, last]`.
2. Append old center to left.
3. Append all removed elements except target to left, in reverse order (last first — preserves carousel order).
4. Target becomes new center.

**Left-scroll batch** mirrors the above.

```swift
func scrollToWindow(_ key: WindowSlot, screen: NSScreen) -> WindowSlot? {
    store.queue.sync(flags: .barrier) {
        guard let id = visibleScrollingRootID(),
              case .scrolling(var root) = store.roots[id] else { return nil }

        let location = location(of: key, in: root)
        guard let location, case .center = location else {} // nil or center → handled below

        let area = screenTilingArea(screen)
        guard case .window(let oldCenter) = root.center else { return nil }

        switch location {
        case .center, nil:
            return nil

        case .right(let index, _):
            guard case .stacking(var stack) = root.right else { return nil }
            let removed = Array(stack.children[index...])
            stack.children.removeSubrange(index...)
            root.right = stack.children.isEmpty ? nil : .stacking(stack)

            appendToSide(oldCenter, side: &root.left, parentId: id, align: .right)
            for win in removed.reversed().dropFirst() {
                appendToSide(win, side: &root.left, parentId: id, align: .right)
            }
            let target = removed.first!
            root.center = .window(target)

        case .left(let index, _):
            guard case .stacking(var stack) = root.left else { return nil }
            let removed = Array(stack.children[index...])
            stack.children.removeSubrange(index...)
            root.left = stack.children.isEmpty ? nil : .stacking(stack)

            appendToSide(oldCenter, side: &root.right, parentId: id, align: .left)
            for win in removed.reversed().dropFirst() {
                appendToSide(win, side: &root.right, parentId: id, align: .left)
            }
            let target = removed.first!
            root.center = .window(target)
        }

        if case .window(let w) = root.center, w.size.width > 0 {
            root.centerWidthFraction = ScrollingPositionService.clampedCenterFraction(
                proposedWidth: w.size.width, screenWidth: area.width)
        }
        position.recomputeSizes(&root, width: area.width, height: area.height,
                                updateSideWindowWidths: false)
        store.roots[id] = .scrolling(root)
        return removed.first
    }
}
```

### 3. Add scrollToCenter on ScrollingFocusService

Orchestrates the scroll: snapshot → mutate → layout → activate. Follows the same two-move pattern as `scrollRight`/`scrollLeft`.

```swift
static func scrollToCenter(key: WindowSlot) {
    guard let screen = NSScreen.main else { return }
    let before = ScrollingTileService.shared.snapshotVisibleScrollingRoot()
    guard let newCenter = ScrollingTileService.shared.scrollToWindow(key, screen: screen) else { return }
    let after = ScrollingTileService.shared.snapshotVisibleScrollingRoot()
    guard let after else { return }
    let zonesChanged = zoneSignature(before) != zoneSignature(after)
    let origin = layoutOrigin(screen: screen)
    let elements = ResizeObserver.shared.elements

    ScrollingLayoutService.shared.applyLayout(root: after, origin: origin, elements: elements,
                                               zonesChanged: zonesChanged, applyCenter: false)
    ScrollingLayoutService.shared.applyLayout(root: after, origin: origin, elements: elements,
                                               applySides: false)
    activateAfterLayout(newCenter)
}
```

### 4. Hook into FocusObserver.applyDim

In `applyDim(pid:)`, after the existing `scrollingRootInfo` branch, check if the focused window is the center. If not, scroll it to center before applying dimming.

```swift
if let info = ScrollingTileService.shared.scrollingRootInfo(containing: key) {
    if info.centerHash != key.windowHash {
        ScrollingFocusService.scrollToCenter(key: key)
        // Re-fetch info after scroll — center hash has changed.
        if let updatedInfo = ScrollingTileService.shared.scrollingRootInfo(containing: key) {
            WindowOpacityService.shared.dim(rootID: updatedInfo.rootID, focusedHash: updatedInfo.centerHash)
        }
    } else {
        WindowOpacityService.shared.dim(rootID: info.rootID, focusedHash: info.centerHash)
    }
}
```

---

## Key Technical Notes

- Stacking slot convention: `children.last` is closest to center (first to be promoted by `scrollRight`/`scrollLeft`). The batch method must preserve this ordering when moving windows across sides.
- `scrollToWindow` preserves the existing `centerWidthFraction` update logic: if the new center window has a stored width, it becomes the new fraction.
- No re-entrancy guard is needed: after scrolling, the focused window is the center, so the next `applyDim` call is a no-op path (`centerHash == key.windowHash`).
- `applyDim` runs on `DispatchQueue.main.async`, so a queued AX focus notification from `activateAfterLayout` will execute after the current scroll completes — the store is consistent by then.
- The two-move layout pattern (sides first, then center) is preserved from the existing scroll methods to maintain visual consistency.

---

## Verification

1. Scroll 3+ windows → click a window in the right side slot → it jumps to center
2. Scroll 3+ windows → Cmd-Tab to an app whose window is in the left side slot → it jumps to center
3. Focus the already-centered window → nothing changes (no-op)
4. Scroll root with only center (no sides) → focus center → nothing changes
5. After auto-scroll, dimming is correct: new center is bright, sides are dimmed
6. Focus Right / Focus Left keyboard shortcuts still work normally (one step at a time)
7. Rapid focus changes (quick Cmd-Tab cycling) don't cause layout corruption
