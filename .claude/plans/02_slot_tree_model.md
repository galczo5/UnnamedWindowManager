# Plan: 19_slot_tree_model — Tree Model for ManagedSlot (Orientation + SlotContent)

## Checklist

- [x] Add `Orientation` enum and `indirect enum SlotContent` to `ManagedTypes.swift`
- [x] Add `height` and `orientation` to `ManagedSlot`; replace `windows` with `content: SlotContent`
- [x] Add `width` to `ManagedWindow`
- [x] Replace `slots: [ManagedSlot]` with `root: ManagedSlot` in `ManagedSlotRegistry`
- [x] Add `initialize(screen:)` to registry — builds root from screen bounds
- [x] Add `snap(_:axElement:screen:)` — tree-mutation snap with find-last + container-replace
- [x] Add `remove(_:screen:)` — find leaf, excise from parent, collapse single-child containers
- [x] Add `recomputeSizes(screen:)` — top-down equal-division pass
- [x] Replace `SnapLayout.applyPosition` with `applyLayout(screen:)` — recursive tree walk
- [x] Delete or stub out `ManagedSlotRegistry+SlotMutations.swift` (flat-array ops obsolete)
- [x] Update `UnnamedWindowManagerApp.swift` Debug display — recursive tree dump
- [x] Disable drop zones — add `return nil` guard at top of `findDropTarget` in `SnapLayout.swift`
- [x] Disable drop zone overlay — add `hideSwapOverlay(); return` guard at top of `updateSwapOverlay` in `ResizeObserver+SwapOverlay.swift`

---

## Context / Problem

`ManagedSlot` is a flat vertical column. This plan replaces it with a recursive tree so layouts can be arbitrarily nested. A single **root slot** per screen covers 100% of its area; snapping windows progressively subdivides the tree.

---

## Data Model Design

```swift
enum Orientation {
    case horizontal
    case vertical
}

indirect enum SlotContent {
    case window(ManagedWindow)
    case slots([ManagedSlot])
}

struct ManagedWindow: Hashable, Sendable {
    let pid: pid_t
    let windowHash: UInt
    var height: CGFloat
    var width: CGFloat          // mirrors the leaf slot's width
    // Hashable/Equatable by identity (pid + windowHash) only
}

struct ManagedSlot {
    var order: Int = 0          // leaf insertion counter; used to identify "last added"
    var width: CGFloat
    var height: CGFloat
    var orientation: Orientation
    var content: SlotContent
}
```

`indirect` on `SlotContent` breaks the mutual recursion between `SlotContent` and `ManagedSlot`.
`DropZone` and `DropTarget` are unaffected.

---

## Registry Structure

```swift
final class ManagedSlotRegistry {
    static let shared = ManagedSlotRegistry()

    var root: ManagedSlot        // single root per main screen
    var windowCount: Int = 0     // increments on every successful snap
}
```

The root is always a container with `orientation = .horizontal` and `content = .slots([...])`.
Its `width`/`height` equal the screen's visible frame dimensions.

---

## Init Behaviour

`ManagedSlotRegistry.initialize(screen:)` is called once at startup (from `WindowEventMonitor.start()` or `UnnamedWindowManagerApp.init()`):

```swift
func initialize(screen: NSScreen) {
    let f = screen.visibleFrame
    root = ManagedSlot(
        order: 0,
        width: f.width,
        height: f.height,
        orientation: .horizontal,
        content: .slots([])
    )
    windowCount = 0
}
```

---

## Layout Rule

### Equal division

After every structural change (snap or remove), `recomputeSizes` walks the tree top-down and sets each node's `width`/`height`:

```swift
// Called with root and the screen's visible frame dimensions.
func recomputeSizes(_ slot: inout ManagedSlot, width: CGFloat, height: CGFloat) {
    slot.width  = width
    slot.height = height
    guard case .slots(var children) = slot.content, !children.isEmpty else { return }

    let n  = CGFloat(children.count)
    let cw: CGFloat
    let ch: CGFloat
    if slot.orientation == .horizontal {
        cw = (width  - Config.gap * (n + 1)) / n
        ch =  height - Config.gap * 2
    } else {
        cw =  width  - Config.gap * 2
        ch = (height - Config.gap * (n + 1)) / n
    }
    for i in children.indices {
        recomputeSizes(&children[i], width: cw, height: ch)
    }
    slot.content = .slots(children)
}
```

### Leaf positioning

`applyLayout` walks the tree and, at every leaf, sets the AX window's position and size to the slot's computed rect:

```swift
// origin is in AX coordinates (top-left origin, y increases downward).
func applyLayout(_ slot: ManagedSlot, origin: CGPoint, elements: [ManagedWindow: AXUIElement]) {
    switch slot.content {
    case .window(let w):
        guard let ax = elements[w] else { return }
        var pos  = origin
        var size = CGSize(width: slot.width, height: slot.height)
        AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString,
                                     AXValueCreate(.cgPoint, &pos)!)
        AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString,
                                     AXValueCreate(.cgSize,  &size)!)

    case .slots(let children):
        var cursor = origin
        for child in children {
            applyLayout(child, origin: cursor, elements: elements)
            if slot.orientation == .horizontal {
                cursor.x += child.width + Config.gap
            } else {
                cursor.y += child.height + Config.gap
            }
        }
    }
}
```

The entry point converts the screen's visible frame to AX coordinates once and passes origin to the recursive call.

---

## Snap Algorithm

When a new window is snapped:

1. **First window** (`windowCount == 0`): append a leaf directly to root's children.
2. **Subsequent windows**: find the leaf slot with the highest `order` (= last added), replace it with a new container, and place the existing leaf and the new leaf inside it.

Container orientation is decided by the **new** `windowCount` (after incrementing):
- `windowCount % 2 == 1` → `.horizontal`
- `windowCount % 2 == 0` → `.vertical`

```
Initial (0 windows):
  root(.horizontal) → []

After snap W1 (windowCount becomes 1):
  root → [leaf(W1, order=1)]

After snap W2 (windowCount becomes 2, 2%2==0 → .vertical):
  last added = leaf(W1, order=1)
  replace with container(.vertical, [leaf(W1), leaf(W2, order=2)])
  root → [container(.vertical)]

After snap W3 (windowCount becomes 3, 3%2==1 → .horizontal):
  last added = leaf(W2, order=2)
  replace with container(.horizontal, [leaf(W2), leaf(W3, order=3)])
  root → [container(.vertical, [leaf(W1), container(.horizontal, [leaf(W2), leaf(W3)])])]

After snap W4 (windowCount becomes 4, 4%2==0 → .vertical):
  last added = leaf(W3, order=3)
  replace with container(.vertical, [leaf(W3), leaf(W4, order=4)])
```

The tree helper `replaceLastLeaf` must be recursive — it finds the maximum-`order` leaf anywhere in the subtree and replaces it in-place:

```swift
// Returns true when the replacement was made (stops further recursion).
@discardableResult
func replaceLastLeaf(
    in slot: inout ManagedSlot,
    targetOrder: Int,
    replacement: ManagedSlot
) -> Bool {
    switch slot.content {
    case .window:
        if slot.order == targetOrder {
            slot = replacement   // replace this node
            return true
        }
        return false
    case .slots(var children):
        for i in children.indices {
            if replaceLastLeaf(in: &children[i], targetOrder: targetOrder, replacement: replacement) {
                slot.content = .slots(children)
                return true
            }
        }
        return false
    }
}
```

Full `snap` method:

```swift
func snap(_ key: ManagedWindow, axElement: AXUIElement, screen: NSScreen) {
    queue.sync(flags: .barrier) {
        windowCount += 1
        let newLeaf = ManagedSlot(
            order: windowCount,
            width: 0, height: 0,            // sized by recomputeSizes
            orientation: .horizontal,        // leaf orientation unused
            content: .window(
                ManagedWindow(pid: key.pid, windowHash: key.windowHash,
                              height: 0, width: 0)
            )
        )

        if case .slots(var children) = root.content, children.isEmpty {
            root.content = .slots([newLeaf])
        } else {
            let lastOrder = maxLeafOrder(in: root)
            let orientation: Orientation = windowCount % 2 == 1 ? .horizontal : .vertical
            var container = ManagedSlot(
                order: 0,
                width: 0, height: 0,
                orientation: orientation,
                content: .slots([])          // filled by replaceLastLeaf
            )
            // Build container: [existingLeaf, newLeaf]
            // replaceLastLeaf finds the existing leaf and wraps it with newLeaf.
            // Easier: extract leaf first, then set container.content.
            extractAndWrap(&root, targetOrder: lastOrder, newLeaf: newLeaf, orientation: orientation)
        }
        recomputeSizes(&root, width: screen.visibleFrame.width,
                               height: screen.visibleFrame.height)
    }
}
```

`extractAndWrap` finds the target leaf, wraps it together with `newLeaf` in a container, and replaces the original leaf node with the container:

```swift
private func extractAndWrap(
    _ slot: inout ManagedSlot,
    targetOrder: Int,
    newLeaf: ManagedSlot,
    orientation: Orientation
) -> Bool {
    if case .window = slot.content, slot.order == targetOrder {
        let existing = slot
        slot = ManagedSlot(
            order: 0,
            width: 0, height: 0,
            orientation: orientation,
            content: .slots([existing, newLeaf])
        )
        return true
    }
    if case .slots(var children) = slot.content {
        for i in children.indices {
            if extractAndWrap(&children[i], targetOrder: targetOrder,
                              newLeaf: newLeaf, orientation: orientation) {
                slot.content = .slots(children)
                return true
            }
        }
    }
    return false
}
```

---

## Remove Algorithm

Finding and removing a leaf requires tree traversal. After removal, if a container ends up with a single child it is **collapsed** (replaced by that child, inheriting the container's size slot):

```swift
// Returns true when the key was found and removed.
@discardableResult
private func removeLeaf(_ key: ManagedWindow, from slot: inout ManagedSlot) -> Bool {
    if case .window(let w) = slot.content, w == key {
        return true   // signal to parent to excise this node
    }
    guard case .slots(var children) = slot.content else { return false }
    for i in children.indices {
        if removeLeaf(key, from: &children[i]) {
            children.remove(at: i)
            // Collapse single-child container.
            if children.count == 1 {
                slot = children[0]
            } else {
                slot.content = .slots(children)
            }
            return true
        }
    }
    return false
}
```

Root is the entry point; after removal call `recomputeSizes` and `applyLayout`.

---

## First-Snap Behaviour

When `windowCount == 0` the root's `content` is `.slots([])`. Snapping the first window appends a single leaf directly into root — no container wrapping:

```
Before:  root(.horizontal) → .slots([])
After:   root(.horizontal) → .slots([leaf(W1, order=1)])
```

`recomputeSizes` then gives leaf(W1) the full available area (root width minus gaps, root height minus gaps), so the first window fills the screen.

No container is created here. The container-wrapping logic in `snap` only runs when `windowCount > 0` (i.e. there is already at least one leaf in the tree).

---

## Disabling Drop Zones

Drop zones rely on flat slot indices and the old `+SlotMutations` operations. They must be **disabled without removing code** so they can be redesigned later for the tree model.

### `SnapLayout.swift` — `findDropTarget`

Add a single early-return at the top of the function body:

```swift
static func findDropTarget(forWindowIn sourceSlotIndex: Int) -> DropTarget? {
    return nil   // TODO: redesign for tree model
    // ... existing code unchanged below ...
}
```

Both callers (`updateSwapOverlay` and `scheduleReapplyWhenMouseUp`) already guard on the return value being non-nil, so returning `nil` causes them to fall through gracefully:
- `updateSwapOverlay` → calls `hideSwapOverlay()` immediately.
- `scheduleReapplyWhenMouseUp` move branch → skips all drop-zone mutations and restores the window's position instead.

### `ResizeObserver+SwapOverlay.swift` — `updateSwapOverlay`

Add a matching guard at the top so the overlay is never shown even if `findDropTarget` were re-enabled separately:

```swift
func updateSwapOverlay(for draggedKey: ManagedWindow, draggedWindow: AXUIElement) {
    hideSwapOverlay()
    return   // TODO: redesign for tree model
    // ... existing code unchanged below ...
}
```

No other files need changes for the disable — `DropZone`, `DropTarget`, and all overlay helpers remain in the codebase untouched.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Model/ManagedTypes.swift` | Add `Orientation`, `indirect enum SlotContent`; update `ManagedSlot` and `ManagedWindow` |
| `UnnamedWindowManager/Model/ManagedSlotRegistry.swift` | Replace `slots` array with `root`; new `initialize`, `snap`, `remove`, `recomputeSizes`, `applyLayout` |
| `UnnamedWindowManager/Model/ManagedSlotRegistry+SlotMutations.swift` | **Delete or empty** — flat-array ops are obsolete; drag-drop rework deferred |
| `UnnamedWindowManager/Snapping/SnapLayout.swift` | Replace `applyPosition` with recursive `applyLayout`; add `return nil` guard to `findDropTarget` |
| `UnnamedWindowManager/Observation/ResizeObserver+SwapOverlay.swift` | Add `hideSwapOverlay(); return` guard at top of `updateSwapOverlay` |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Update `initialize` call site; update Debug to recursively dump the tree |

---

## Key Technical Notes

- `indirect` on `SlotContent` (not `ManagedSlot`) is sufficient to break the recursive value-type cycle.
- `recomputeSizes` must be called before `applyLayout`; sizes flow top-down and positions flow from the computed sizes.
- Root is never a leaf — its `content` is always `.slots([...])`, even when empty. This simplifies all tree mutations.
- The collapse rule (single-child container → replaced by child) keeps the tree minimal. Without it, repeated snap/remove cycles accumulate single-child wrappers.
- `windowCount` is the global snap counter, not the current count of live windows. It only increments; use `leafCount(in: root)` when you need the live count.
- `order` on leaf slots is their global insertion index. The "last added" leaf is `maxLeafOrder(in: root)`. Container nodes carry `order = 0` and are ignored by this search.
- Gap accounting: horizontal split of width `W` into `N` children → `(W - gap*(N+1)) / N` per child. This matches the existing `Config.gap` pattern already used in `equalizeHeights`.
- `ManagedSlotRegistry+SlotMutations.swift` (drag-drop operations) depends on the flat-array model and cannot be trivially ported. Stub it out or delete it; drag-drop redesign is a separate plan.
- Drop zones are disabled by two `return`/`return nil` guards, not by removing code. `DropZone`, `DropTarget`, all overlay helpers, and all `+SlotMutations` operations remain in the codebase as-is for future redesign.
- AX coordinates: origin is top-left, y increases downward. `applyLayout` receives the screen's AX origin `(visible.minX + gap, primaryHeight - visible.maxY + gap)` and advances the cursor by `child.width + gap` (horizontal) or `child.height + gap` (vertical).

---

## Verification

1. Launch app → `initialize` creates root with full screen dimensions.
2. Snap W1 → root has one leaf child; window fills screen (minus gaps).
3. Snap W2 → root's single child replaced by `.vertical` container holding W1 (top half) and W2 (bottom half).
4. Snap W3 → W2's leaf replaced by `.horizontal` container; W2 left, W3 right, each 50% of W2's former area.
5. Close W2 → its leaf removed; container collapses; W3 takes W2's former position.
6. Debug alert shows indented tree dump with width/height per node.
