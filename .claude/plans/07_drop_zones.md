# Plan: 07_drop_zones — Directional Drop Zones During Window Drag

## Checklist

- [x] Add `DropZone` enum and `DropTarget` struct (`Model/DropTarget.swift`)
- [x] Update `findSwapTarget` → `findDropTarget` in `ReapplyHandler`
- [x] Add `insertAdjacentTo` in `SlotTreeService`
- [x] Add `insertAdjacent` in `SnapService`
- [x] Update `updateSwapOverlay` to show partial zone overlay
- [x] Update `ResizeObserver.handle` to pass `DropTarget` to overlay
- [x] Update `scheduleReapplyWhenMouseUp` to use `findDropTarget` and call `insertAdjacent`

---

## Context / Problem

Currently, dragging a managed window onto another managed window triggers a **swap** — the two windows exchange positions in the slot tree. There is no concept of a drop zone; the entire target window frame is the drop target.

The goal is to replace (or extend) this with **four directional drop zones** per window slot:

- **Left** — insert dragged window to the left of target in a `HorizontalSlot`
- **Right** — insert dragged window to the right of target in a `HorizontalSlot`
- **Top** — insert dragged window above target in a `VerticalSlot`
- **Bottom** — insert dragged window below target in a `VerticalSlot`

If the target's parent slot already has the matching orientation, the dragged window is inserted directly into that existing container (no extra nesting). Otherwise, the target is wrapped in a new container of the needed orientation.

The existing center-of-window area retains the current swap behavior.

`Config.swift` already defines the zone fractions: `dropZoneFraction` (left/right, 20% each), `dropZoneTopFraction` (20% from top), `dropZoneBottomFraction` (20% from bottom).

---

## Behaviour spec

**Zone detection** (cursor in AppKit coords, evaluated against target window frame):

| Zone | Condition |
|------|-----------|
| `.left` | `cursor.x < frame.minX + frame.width * dropZoneFraction` |
| `.right` | `cursor.x > frame.maxX - frame.width * dropZoneFraction` |
| `.top` (AppKit y↑) | `cursor.y > frame.maxY - frame.height * dropZoneTopFraction` |
| `.bottom` | `cursor.y < frame.minY + frame.height * dropZoneBottomFraction` |
| center | none of the above → existing swap behavior |

Left/right are checked before top/bottom so corners prefer horizontal zones.

**Tree mutation rules** for zone `.left` / `.right` (orientation = `.horizontal`):

- If target's parent is already `.horizontal` (or `RootSlot` with `.horizontal` orientation): insert dragged into that container at the correct index (before target for `.left`, after for `.right`).
- Otherwise: replace target node in its parent with a new `HorizontalSlot([dragged, target])` for `.left` or `HorizontalSlot([target, dragged])` for `.right`.

Same pattern for `.top` / `.bottom` with `.vertical`.

**Fractions**: when inserting into an existing container, give dragged `0.5 * target.fraction` and halve target's fraction (equal split of the target's share). When wrapping in a new container, each child gets `fraction = 0.5`; the new container inherits the target's fraction and parentId.

**Dragged window removal**: the dragged window is removed from the tree first (standard `removeLeaf`), then re-inserted via `insertAdjacentTo`. This means all indices and fractions are recomputed after removal before insertion.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Model/DropTarget.swift` | **New file** — `DropZone` enum and `DropTarget` struct |
| `UnnamedWindowManager/System/ReapplyHandler.swift` | Modify — add `findDropTarget`, keep `findSwapTarget` renamed internally |
| `UnnamedWindowManager/Services/SlotTreeService.swift` | Modify — add `insertAdjacentTo` public method + private helpers |
| `UnnamedWindowManager/Services/SnapService.swift` | Modify — add `insertAdjacent` method |
| `UnnamedWindowManager/Observation/ResizeObserver+SwapOverlay.swift` | Modify — accept `DropTarget` and show partial frame overlay |
| `UnnamedWindowManager/Observation/ResizeObserver.swift` | Modify — pass `DropTarget` to `updateSwapOverlay` during drag |
| `UnnamedWindowManager/Observation/ResizeObserver+Reapply.swift` | Modify — use `findDropTarget`, branch on zone vs swap vs restore |

---

## Implementation Steps

### 1. Add `DropZone` and `DropTarget` types

New file `Model/DropTarget.swift`:

```swift
enum DropZone {
    case left, right, top, bottom
}

struct DropTarget {
    let window: WindowSlot
    let zone: DropZone
}
```

---

### 2. Update `ReapplyHandler.findSwapTarget` → `findDropTarget`

Replace the existing `findSwapTarget(forKey:) -> WindowSlot?` with `findDropTarget(forKey:) -> DropTarget?`. Keep a thin `findSwapTarget` shim that calls `findDropTarget` and returns only the window (for the swap center-zone path).

```swift
static func findDropTarget(forKey draggedKey: WindowSlot) -> DropTarget? {
    let cursor = NSEvent.mouseLocation
    let screenHeight = NSScreen.screens[0].frame.height
    let leaves = SnapService.shared.allLeaves()
    let elements = ResizeObserver.shared.elements

    for leaf in leaves {
        guard case .window(let w) = leaf, w != draggedKey else { continue }
        guard let axElement = elements[w],
              let axOrigin = readOrigin(of: axElement),
              let axSize   = readSize(of: axElement) else { continue }

        let appKitY = screenHeight - axOrigin.y - axSize.height
        let frame = CGRect(x: axOrigin.x, y: appKitY,
                           width: axSize.width, height: axSize.height)
        guard frame.contains(cursor) else { continue }

        // Zone detection — left/right take priority over top/bottom
        if cursor.x < frame.minX + frame.width * Config.dropZoneFraction {
            return DropTarget(window: w, zone: .left)
        }
        if cursor.x > frame.maxX - frame.width * Config.dropZoneFraction {
            return DropTarget(window: w, zone: .right)
        }
        if cursor.y > frame.maxY - frame.height * Config.dropZoneTopFraction {
            return DropTarget(window: w, zone: .top)
        }
        if cursor.y < frame.minY + frame.height * Config.dropZoneBottomFraction {
            return DropTarget(window: w, zone: .bottom)
        }
        // Center — treat as swap target (no zone)
        return DropTarget(window: w, zone: .left) // placeholder; see note below
    }
    return nil
}
```

> **Note:** The center zone should return `nil` zone to keep swap behavior. A cleaner approach is to make `DropZone` have a `.swap` case, or return `nil` for the center and handle swap separately. The simplest approach: return `DropTarget?` for directional zones, and keep `findSwapTarget` (unchanged original) for the center/swap path. Both are called at mouse-up; directional takes priority if a zone is detected.

A cleaner design: `findDropTarget` returns `DropTarget?` for directional zones only (center → `nil`). `findSwapTarget` remains as-is for center swap. At mouse-up, check `findDropTarget` first; fall back to `findSwapTarget` if nil.

---

### 3. Add `insertAdjacentTo` in `SlotTreeService`

The algorithm traverses the tree looking for the target's **parent** container, then either inserts directly or wraps:

```swift
func insertAdjacentTo(
    _ dragged: Slot,
    adjacentTo targetKey: WindowSlot,
    zone: DropZone,
    in root: inout RootSlot
) {
    let needed: Orientation = (zone == .left || zone == .right) ? .horizontal : .vertical
    let draggedFirst = (zone == .left || zone == .top)

    // Check root-level children first
    if let idx = root.children.firstIndex(where: {
        if case .window(let w) = $0 { return w == targetKey }
        return false
    }) {
        if root.orientation == needed {
            insertIntoArray(&root.children, dragged: dragged, at: idx, draggedFirst: draggedFirst)
        } else {
            root.children[idx] = wrapped(target: root.children[idx], dragged: dragged,
                                         needed: needed, draggedFirst: draggedFirst)
        }
        return
    }

    // Recurse into children
    for i in root.children.indices {
        if insertAdjacentInSlot(&root.children[i], targetKey: targetKey,
                                 dragged: dragged, needed: needed,
                                 draggedFirst: draggedFirst) { return }
    }
}
```

Private helpers:

```swift
// Inserts dragged adjacent to the child at `targetIdx` and redistributes fractions.
private func insertIntoArray(_ children: inout [Slot], dragged: Slot,
                              at targetIdx: Int, draggedFirst: Bool) {
    let targetFraction = children[targetIdx].fraction
    var d = dragged;      d.fraction = targetFraction / 2
    var t = children[targetIdx]; t.fraction = targetFraction / 2
    children[targetIdx] = t
    let insertAt = draggedFirst ? targetIdx : targetIdx + 1
    children.insert(d, at: insertAt)
}

// Wraps the target in a new container of `needed` orientation.
private func wrapped(target: Slot, dragged: Slot,
                     needed: Orientation, draggedFirst: Bool) -> Slot {
    let containerId = UUID()
    var d = dragged; d.parentId = containerId; d.fraction = 0.5
    var t = target;  t.parentId = containerId; t.fraction = 0.5
    let children: [Slot] = draggedFirst ? [d, t] : [t, d]
    return needed == .horizontal
        ? .horizontal(HorizontalSlot(id: containerId, parentId: target.parentId,
                                     width: 0, height: 0, children: children,
                                     fraction: target.fraction))
        : .vertical(VerticalSlot(id: containerId, parentId: target.parentId,
                                 width: 0, height: 0, children: children,
                                 fraction: target.fraction))
}

// Recursive helper. Returns true when the target was found and handled.
@discardableResult
private func insertAdjacentInSlot(
    _ slot: inout Slot,
    targetKey: WindowSlot,
    dragged: Slot,
    needed: Orientation,
    draggedFirst: Bool
) -> Bool {
    switch slot {
    case .window: return false
    case .horizontal(var h):
        if let idx = h.children.firstIndex(where: {
            if case .window(let w) = $0 { return w == targetKey }; return false
        }) {
            if needed == .horizontal {
                insertIntoArray(&h.children, dragged: dragged, at: idx, draggedFirst: draggedFirst)
            } else {
                h.children[idx] = wrapped(target: h.children[idx], dragged: dragged,
                                          needed: needed, draggedFirst: draggedFirst)
            }
            slot = .horizontal(h); return true
        }
        for i in h.children.indices {
            if insertAdjacentInSlot(&h.children[i], targetKey: targetKey,
                                     dragged: dragged, needed: needed,
                                     draggedFirst: draggedFirst) {
                slot = .horizontal(h); return true
            }
        }
        return false
    case .vertical(var v):
        // mirror of horizontal case with .vertical / VerticalSlot
        ...
        slot = .vertical(v); return true
    }
}
```

---

### 4. Add `insertAdjacent` in `SnapService`

```swift
func insertAdjacent(dragged: WindowSlot, target: WindowSlot,
                    zone: DropZone, screen: NSScreen) {
    store.queue.sync(flags: .barrier) {
        // Capture order before removal
        guard let draggedSlot = tree.findLeafSlot(dragged, in: store.root),
              case .window(let draggedWindow) = draggedSlot else { return }

        tree.removeLeaf(dragged, from: &store.root)

        let newLeaf = Slot.window(WindowSlot(
            pid: draggedWindow.pid, windowHash: draggedWindow.windowHash,
            id: UUID(), parentId: store.root.id,
            order: draggedWindow.order,
            width: 0, height: 0, gaps: true
        ))

        tree.insertAdjacentTo(newLeaf, adjacentTo: target,
                              zone: zone, in: &store.root)

        position.recomputeSizes(&store.root,
                                width: screen.visibleFrame.width  - Config.gap * 2,
                                height: screen.visibleFrame.height - Config.gap * 2)
    }
}
```

---

### 5. Update `updateSwapOverlay` to show partial zone overlay

Change signature to `updateSwapOverlay(dropTarget: DropTarget?, draggedWindow: AXUIElement)`.

Compute the zone sub-frame from the full target frame:

```swift
func zoneFrame(for zone: DropZone, in full: CGRect) -> CGRect {
    switch zone {
    case .left:
        return CGRect(x: full.minX, y: full.minY,
                      width: full.width / 2, height: full.height)
    case .right:
        return CGRect(x: full.minX + full.width / 2, y: full.minY,
                      width: full.width / 2, height: full.height)
    case .top:    // AppKit y↑: top of window = high y values
        return CGRect(x: full.minX, y: full.minY + full.height / 2,
                      width: full.width, height: full.height / 2)
    case .bottom:
        return CGRect(x: full.minX, y: full.minY,
                      width: full.width, height: full.height / 2)
    }
}
```

Call `showSwapOverlay(frame: zoneFrame(...), belowWindow: ...)` with the computed partial frame.

---

### 6. Update `ResizeObserver.handle` — pass `DropTarget` during drag

In `ResizeObserver.swift`, during live drag (line ~85), replace:

```swift
// Before
updateSwapOverlay(for: key, draggedWindow: element)
```

with:

```swift
// After
let drop = ReapplyHandler.findDropTarget(forKey: key)
updateSwapOverlay(dropTarget: drop, draggedWindow: element)
```

The `updateSwapOverlay` implementation reads the window frame for `drop?.window` and shows the partial zone overlay (or hides it if `drop == nil`).

---

### 7. Update `scheduleReapplyWhenMouseUp` — branch on zone type

In `ResizeObserver+Reapply.swift`, replace the move path:

```swift
// Before
if let swapTarget = ReapplyHandler.findSwapTarget(forKey: key) {
    SnapService.shared.swap(key, swapTarget)
    ...
} else {
    ReapplyHandler.reapply(...)
}
```

```swift
// After
if let drop = ReapplyHandler.findDropTarget(forKey: key) {
    let allWindows = self.allTrackedWindows()
    self.reapplying.formUnion(allWindows)
    SnapService.shared.insertAdjacent(dragged: key, target: drop.window,
                                      zone: drop.zone, screen: screen)
    ReapplyHandler.reapplyAll()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.reapplying.subtract(allWindows)
    }
} else if let swapTarget = ReapplyHandler.findSwapTarget(forKey: key) {
    // Center zone: retain existing swap behaviour
    let allWindows = self.allTrackedWindows()
    self.reapplying.formUnion(allWindows)
    SnapService.shared.swap(key, swapTarget)
    ReapplyHandler.reapplyAll()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.reapplying.subtract(allWindows)
    }
} else {
    self.reapplying.insert(key)
    ReapplyHandler.reapply(window: storedElement, key: key)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.reapplying.remove(key)
    }
}
```

---

## Key Technical Notes

- `findDropTarget` is called on the **main thread** (inside AX callback / DispatchWorkItem on main queue) — same as `findSwapTarget`, so no threading issues.
- Zone priority: left/right before top/bottom avoids ambiguity in corners. Corners are 20% × 20% squares; left/right capture the full column, so corners go to left/right.
- `insertIntoArray` sets `parentId` on the new dragged slot only after insertion — `parentId` in the inserted leaf must be the container's `id`, not `store.root.id`. The helper must set `d.parentId = container.id` before inserting. In `insertIntoArray` for the root-level case, use `store.root.id`; for the slot-level case, use the container's `id`.
- After `removeLeaf`, the target slot may have been promoted (e.g., if dragged and target were the only two children in a container, the container collapses and target is promoted to its grandparent). `insertAdjacentTo` must handle the potentially-changed tree.
- `position.recomputeSizes` is always called after structural mutations — do not skip it.
- The overlay `zoneFrame` uses AppKit coordinates (y=0 at bottom). "Top of window" = high `y` values in the frame rect. Verify with `top` and `bottom` zones on screen.
- AX coordinate origin is top-left; AppKit is bottom-left. The existing `appKitY = screenHeight - axOrigin.y - axSize.height` conversion in `updateSwapOverlay` is correct and must be preserved.
- `Config.dropZoneFraction`, `dropZoneTopFraction`, `dropZoneBottomFraction` are already defined — use them, don't hard-code values.

---

## Verification

1. Snap three windows A, B, C in a horizontal layout (A | B | C).
2. Drag A onto the **left zone** of C → result should be (A | C) | B or B | (A | C) depending on insertion — specifically B | (A | C) since C's parent is the root horizontal, so A is inserted before C at the root level → B | A | C (flat, 3 children).
3. Drag A onto the **right zone** of B → A inserted after B: B | A | C (or the current tree state).
4. Drag A onto the **top zone** of B → B is wrapped in a vertical container: root has (A over B) | C.
5. Drag A onto the **bottom zone** of B → root has (B over A) | C.
6. Verify the overlay shows only the half of the target window corresponding to the zone (left half, right half, top half, bottom half).
7. Verify dragging to the center of a window still triggers the existing swap behavior.
8. Snap a single window, then drag it — verify no crash when no drop target exists.
9. Drag a window onto a zone of a window that shares a parent of the matching orientation → verify flat insertion (no extra nesting).
