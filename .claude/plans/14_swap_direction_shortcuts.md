# Plan: 14_swap_direction_shortcuts — Directional Swap Shortcuts

## Checklist

- [x] Create `DirectionalNeighborService.swift` with extracted neighbor-finding logic
- [x] Update `FocusDirectionService.swift` to delegate to `DirectionalNeighborService`
- [x] Add `swapWindows(_:_:)` to `ScrollingTileService.swift`
- [x] Create `SwapDirectionService.swift`
- [x] Create `SwapLeftHandler.swift`
- [x] Create `SwapRightHandler.swift`
- [x] Create `SwapUpHandler.swift`
- [x] Create `SwapDownHandler.swift`
- [x] Add 4 swap shortcut fields to `ConfigData.swift` (`ShortcutsConfig` + `defaults` + `missingKeys` + `mergedWithDefaults`)
- [x] Add 4 swap shortcut accessors to `Config.swift`
- [x] Register 4 shortcuts in `KeybindingService.swift`

---

## Context / Problem

There are four focus shortcuts (focusLeft, focusRight, focusUp, focusDown) that move keyboard focus to the nearest directional neighbor. The goal is to add four parallel swap shortcuts that instead exchange positions of the focused window and its directional neighbor, leaving focus on the moved window.

The target-selection algorithm (directional nearest-neighbor via rect overlap + distance) is currently embedded in `FocusDirectionService`. It must be extracted into a reusable service so both focus and swap can use it.

---

## Behaviour spec

**Regular tiling layout**: swap the `pid`/`windowHash` of the focused window slot with the nearest directional neighbor slot. Slot fractions (sizes) are preserved — only the window identities move. Uses `TileService.swap()` which delegates to `SlotTreeInsertService.swap()` (three-pass sentinel pattern).

**ScrollRoot layout**:
- `swapLeft`: center ↔ last child of left `StackingSlot` (the child closest to center). Only the window identity swapped within the slot; slot dimensions untouched.
- `swapRight`: center ↔ last child of right `StackingSlot`.
- `swapUp` / `swapDown`: no-op (ScrollRoot has no vertical neighbour concept).

The distinction from `scrollLeft`/`scrollRight`: those rotate the center to the opposite stacking slot. Swap keeps the window at the same slot position — just exchanges the two nearest windows.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/DirectionalNeighborService.swift` | **New file** — extracted spatial logic from `FocusDirectionService` |
| `UnnamedWindowManager/Services/FocusDirectionService.swift` | Modify — remove extracted internals, call `DirectionalNeighborService` |
| `UnnamedWindowManager/Services/ScrollingTileService.swift` | Modify — add `swapWindows(_:_:)` |
| `UnnamedWindowManager/Services/SwapDirectionService.swift` | **New file** — orchestrates directional swap for both layout types |
| `UnnamedWindowManager/System/SwapLeftHandler.swift` | **New file** |
| `UnnamedWindowManager/System/SwapRightHandler.swift` | **New file** |
| `UnnamedWindowManager/System/SwapUpHandler.swift` | **New file** |
| `UnnamedWindowManager/System/SwapDownHandler.swift` | **New file** |
| `UnnamedWindowManager/ConfigData.swift` | Modify — add 4 shortcut fields |
| `UnnamedWindowManager/Config.swift` | Modify — add 4 shortcut accessors |
| `UnnamedWindowManager/Services/KeybindingService.swift` | Modify — register 4 shortcuts |

---

## Implementation Steps

### 1. Create `DirectionalNeighborService`

Move `LeafRect`, `Axis`, `leafRects()`, `collectLeafRects()`, and `nearest()` out of `FocusDirectionService` into a new file. Expose one public entry point that returns the neighbour key given the focused window key and the visible tiling root.

```swift
// Spatial neighbour-finding for directional window operations.
struct DirectionalNeighborService {

    struct LeafRect {
        let key: WindowSlot
        let rect: CGRect
    }

    static func findNeighbor(
        of currentKey: WindowSlot,
        direction: FocusDirection,
        in root: TilingRootSlot
    ) -> WindowSlot? {
        let rects = leafRects(in: root)
        guard let sourceRect = rects.first(where: { $0.key == currentKey })?.rect else { return nil }
        return nearest(from: sourceRect, direction: direction, candidates: rects, exclude: currentKey)
    }

    // leafRects(), collectLeafRects(), nearest() moved verbatim from FocusDirectionService
    // Axis enum moved here too (keep private)
}
```

### 2. Update `FocusDirectionService`

Remove `LeafRect`, `Axis`, `leafRects()`, `collectLeafRects()`, and `nearest()`. Update `focus()` to call `DirectionalNeighborService.findNeighbor(of:direction:in:)`.

```swift
static func focus(_ direction: FocusDirection) {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
    let pid = frontApp.processIdentifier
    let axApp = AXUIElementCreateApplication(pid)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success else { return }
    let axWindow = ref as! AXUIElement
    let currentKey = windowSlot(for: axWindow, pid: pid)
    guard let root = TileService.shared.snapshotVisibleRoot() else { return }
    guard let targetKey = DirectionalNeighborService.findNeighbor(of: currentKey, direction: direction, in: root) else { return }
    activateWindow(targetKey)
}
```

### 3. Add `swapWindows` to `ScrollingTileService`

Exchanges just the `pid`/`windowHash` of the center window with the last child of the left or right `StackingSlot`. Uses a sentinel pattern matching `SlotTreeInsertService` to swap in place.

```swift
func swapWindows(_ keyA: WindowSlot, _ keyB: WindowSlot) {
    store.queue.sync(flags: .barrier) {
        guard let id = visibleScrollingRootID(),
              case .scrolling(var root) = store.roots[id] else { return }

        // Find and swap the pid+windowHash of keyA and keyB within the ScrollRoot model.
        // The slot structure (positions/sizes) is untouched — only window identity moves.
        replaceWindowKey(&root, target: keyA, with: keyB, via: keyA) // use sentinel pattern
        store.roots[id] = .scrolling(root)
    }
}
```

The simplest correct implementation uses the same three-pass sentinel approach. Alternatively, implement a helper that walks center / left children / right children, finds the two indices, and swaps them directly (preferred for clarity in a ScrollRoot):

```swift
// In store.queue barrier block:
var centerWin: WindowSlot? = nil
var stackSide: WritableKeyPath<ScrollingRootSlot, Slot?>? = nil
var stackIdx: Int? = nil

if case .window(let w) = root.center, w == keyA { centerWin = w }
// ... find keyB in left/right stacking children
// Then: root.center = .window(keyB); leftStack.children[idx] = keyA
```

Use whichever approach is cleaner at implementation time.

### 4. Create `SwapDirectionService`

```swift
// Swaps the focused window with its directional neighbour, for both tiling and scrolling layouts.
struct SwapDirectionService {

    static func swap(_ direction: FocusDirection) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success else { return }
        let axWindow = ref as! AXUIElement
        let currentKey = windowSlot(for: axWindow, pid: pid)

        if ScrollingTileService.shared.snapshotVisibleScrollingRoot() != nil {
            swapInScrollRoot(direction: direction, currentKey: currentKey)
        } else {
            swapInTilingRoot(direction: direction, currentKey: currentKey)
        }
    }

    private static func swapInScrollRoot(direction: FocusDirection, currentKey: WindowSlot) {
        guard direction == .left || direction == .right else { return }
        // Ask ScrollingTileService for the adjacent window in the given direction,
        // then call swapWindows(_:_:).
        guard let neighbor = ScrollingTileService.shared.neighborKey(direction: direction) else { return }
        ScrollingTileService.shared.swapWindows(currentKey, neighbor)
        ReapplyHandler.reapplyAll()
    }

    private static func swapInTilingRoot(direction: FocusDirection, currentKey: WindowSlot) {
        guard let root = TileService.shared.snapshotVisibleRoot() else { return }
        guard let targetKey = DirectionalNeighborService.findNeighbor(of: currentKey, direction: direction, in: root) else { return }
        TileService.shared.swap(currentKey, targetKey)
        ReapplyHandler.reapplyAll()
    }
}
```

`ScrollingTileService.neighborKey(direction:)` is a new read-only helper that returns the `WindowSlot` of the center's immediate left or right neighbour (last child of the respective stacking slot) without mutating state. Add it alongside `swapWindows`.

### 5. Create the 4 handler files

Each follows the same pattern as the focus handlers:

```swift
// SwapLeftHandler.swift
// Entry point for the swap-left shortcut.
struct SwapLeftHandler {
    static func swap() {
        SwapDirectionService.swap(.left)
    }
}
```

Repeat for Right, Up, Down (Up/Down do not need a ScrollRoot guard since `SwapDirectionService` already no-ops when direction is `.up`/`.down` in a ScrollRoot).

### 6. Add config fields

**`ConfigData.swift` — `ShortcutsConfig`**:
```swift
var swapLeft: String?
var swapRight: String?
var swapUp: String?
var swapDown: String?
```

**`ConfigData.defaults`** — add to `ShortcutsConfig(...)`:
```swift
swapLeft: "", swapRight: "", swapUp: "", swapDown: ""
```
(Empty string = unbound by default.)

**`missingKeys`** — add four `check(s?.shortcuts?.swapLeft, "config.shortcuts.swapLeft")` calls.

**`mergedWithDefaults`** — add four merge lines following the existing pattern.

### 7. Add `Config` accessors

```swift
static var swapLeftShortcut: String  { shared.s.shortcuts!.swapLeft! }
static var swapRightShortcut: String { shared.s.shortcuts!.swapRight! }
static var swapUpShortcut: String    { shared.s.shortcuts!.swapUp! }
static var swapDownShortcut: String  { shared.s.shortcuts!.swapDown! }
```

### 8. Register shortcuts in `KeybindingService`

Add four entries to `makeBuiltInCandidates()`:

```swift
(Config.swapLeftShortcut,  "swapLeft",  { SwapLeftHandler.swap() }),
(Config.swapRightShortcut, "swapRight", { SwapRightHandler.swap() }),
(Config.swapUpShortcut,    "swapUp",    { SwapUpHandler.swap() }),
(Config.swapDownShortcut,  "swapDown",  { SwapDownHandler.swap() }),
```

---

## Key Technical Notes

- `collectLeafRects()` in `FocusDirectionService` calls `fatalError` on `.stacking` — this is intentional for tiling roots. `DirectionalNeighborService` must preserve this behaviour; ScrollRoot swap uses a separate path, never calling `leafRects`.
- `ReapplyHandler.reapplyAll()` already calls `PostResizeValidator.checkAndFixRefusals` internally (see `ReapplyHandler.swift:41`) — no need to call the validator separately in swap handlers.
- `TileService.swap()` uses the three-pass sentinel pattern in `SlotTreeInsertService` — swap is safe across subtrees.
- Empty-string shortcuts (`""`) are skipped by `buildBindings` (see `KeybindingService` line 88: `compactMap { s.isEmpty ? nil : s }`), so unbound defaults are safe.
- `neighborKey(direction:)` on `ScrollingTileService` must be called inside `store.queue.sync` (read-only) and must not mutate state — expose it as a non-barrier sync call returning an optional `WindowSlot`.

---

## Verification

1. Bind `swapLeft` / `swapRight` / `swapUp` / `swapDown` in `~/.config/unnamed/config.yml`.
2. Snap 4 windows in a 2×2 tiling layout → fire swapLeft on the top-right window → top-right and top-left windows exchange positions; layout sizes unchanged.
3. Confirm focus remains on the moved window (it is now in the top-left slot).
4. Fire swapDown from the top-left window → top-left and bottom-left exchange positions.
5. Fire swapRight from top-left → top-left and top-right exchange back.
6. In ScrollRoot with 3+ windows: fire swapLeft → center and left-adjacent window exchange; sizes unchanged; center is now the previously-adjacent window.
7. In ScrollRoot: fire swapRight → center and right-adjacent exchange.
8. In ScrollRoot: fire swapUp/swapDown → no visible change (no-op).
9. Existing focus shortcuts still work correctly (regression check on `FocusDirectionService` refactor).
10. Build with no compiler errors or warnings.
