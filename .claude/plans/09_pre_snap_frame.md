# Plan: 19_pre_snap_frame — Restore window frame on unsnap

## Checklist

- [x] Add `preSnapOrigin` and `preSnapSize` to `WindowSlot`
- [x] Capture pre-snap frame in `SnapHandler`
- [x] Capture pre-snap frame in `OrganizeHandler`
- [x] Preserve pre-snap values through `SnapService.snap()` (fresh + cross-root)
- [x] Copy pre-snap values in `SnapService.insertAdjacent()`
- [x] Swap pre-snap values in `SlotTreeInsertService.replaceWindowInLeaf()`
- [x] Add `storedSlot(_:)` query to `SnapService`
- [x] Create `RestoreService` with frame-restore logic
- [x] Call `RestoreService` in `UnsnapHandler.unsnap()`
- [x] Call `RestoreService` in `UnsnapHandler.unsnapAll()`

---

## Context / Problem

When a window is unsnapped, it keeps its current tiled frame instead of returning to its original size and position. Users expect unsnap to reverse the snap — putting the window back where it was.

**Goal:** Store the window's pre-snap origin and size in `WindowSlot`, assign them once at snap time, carry them through swap/move operations, and restore them on unsnap.

---

## Files to create / modify

| File | Action |
|------|--------|
| `Model/Slot.swift` | Modify — add `preSnapOrigin` and `preSnapSize` to `WindowSlot` |
| `System/SnapHandler.swift` | Modify — read AX frame before snap, set on key |
| `System/OrganizeHandler.swift` | Modify — read AX frame before snap, set on key |
| `Services/SnapService.swift` | Modify — preserve pre-snap values through snap/insertAdjacent; add `storedSlot` query |
| `Services/SlotTreeInsertService.swift` | Modify — swap pre-snap values with identity in `replaceWindowInLeaf` |
| `System/RestoreService.swift` | **New file** — restores a window's pre-snap frame via AX API |
| `System/UnsnapHandler.swift` | Modify — call `RestoreService` on unsnap/unsnapAll |

---

## Implementation Steps

### 1. Add fields to `WindowSlot`

Add two optional fields to `WindowSlot` in `Slot.swift`:

```swift
var preSnapOrigin: CGPoint?
var preSnapSize: CGSize?
```

Both default to `nil`. No changes needed to `Hashable`/`Equatable` — identity remains `(pid, windowHash)`.

All existing init call sites (AXHelpers, SlotTreeInsertService sentinel, etc.) continue to work since the new fields have default values.

### 2. Capture pre-snap frame in `SnapHandler`

In both `snap()` and `snapLeft()`, read the window's current origin and size before calling `SnapService.snap()`, and set them on the key:

```swift
var key = windowSlot(for: axWindow, pid: pid)
key.preSnapOrigin = readOrigin(of: axWindow)
key.preSnapSize = readSize(of: axWindow)
```

### 3. Capture pre-snap frame in `OrganizeHandler`

In the snap loop, read each window's frame before snapping:

```swift
var key = windowSlot(for: item.window, pid: item.pid)
key.preSnapOrigin = readOrigin(of: item.window)
key.preSnapSize = readSize(of: item.window)
```

### 4. Preserve pre-snap values in `SnapService.snap()`

When creating the `newLeaf`, copy the pre-snap values. For cross-root migration, preserve the original pre-snap values from the existing slot rather than using the (now-tiled) frame from the key:

```swift
var preSnapOrigin = key.preSnapOrigin
var preSnapSize = key.preSnapSize

if let srcID = rootIDSync(containing: key) {
    // Preserve original pre-snap values from existing slot during cross-root migration.
    if let oldSlot = treeQuery.findLeafSlot(key, in: store.roots[srcID]!),
       case .window(let oldWindow) = oldSlot {
        preSnapOrigin = oldWindow.preSnapOrigin
        preSnapSize = oldWindow.preSnapSize
    }
    treeMutation.removeLeaf(key, from: &store.roots[srcID]!)
    ...
}

let newLeaf = Slot.window(WindowSlot(
    pid: key.pid, windowHash: key.windowHash,
    id: UUID(), parentId: ..., order: order, width: 0, height: 0, gaps: true,
    preSnapOrigin: preSnapOrigin, preSnapSize: preSnapSize
))
```

### 5. Copy pre-snap values in `SnapService.insertAdjacent()`

The `draggedWindow` already carries pre-snap values. Copy them to the new leaf:

```swift
let newLeaf = Slot.window(WindowSlot(
    pid: draggedWindow.pid, windowHash: draggedWindow.windowHash,
    id: UUID(), parentId: ..., order: draggedWindow.order, width: 0, height: 0, gaps: true,
    preSnapOrigin: draggedWindow.preSnapOrigin, preSnapSize: draggedWindow.preSnapSize
))
```

### 6. Swap pre-snap values in `SlotTreeInsertService.replaceWindowInLeaf()`

Pre-snap values travel with the window identity (pid/windowHash), not with the tree position. In `replaceWindowInLeaf`, copy `preSnapOrigin` and `preSnapSize` from `replacement`:

```swift
let swapped = WindowSlot(
    pid: replacement.pid, windowHash: replacement.windowHash,
    id: w.id, parentId: w.parentId, order: w.order,
    width: w.width, height: w.height, gaps: w.gaps, fraction: w.fraction,
    preSnapOrigin: replacement.preSnapOrigin, preSnapSize: replacement.preSnapSize
)
```

### 7. Add `storedSlot(_:)` query to `SnapService`

Add a method to look up the full stored `WindowSlot` by identity:

```swift
func storedSlot(_ key: WindowSlot) -> WindowSlot? {
    store.queue.sync {
        for root in store.roots.values {
            if let slot = treeQuery.findLeafSlot(key, in: root),
               case .window(let w) = slot { return w }
        }
        return nil
    }
}
```

### 8. Create `RestoreService`

New file `System/RestoreService.swift` that encapsulates setting a window's frame back to its pre-snap values:

```swift
struct RestoreService {
    static func restore(_ slot: WindowSlot, element: AXUIElement) {
        guard var pos = slot.preSnapOrigin, var size = slot.preSnapSize else { return }
        if let posVal = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
        }
    }
}
```

### 9. Call `RestoreService` in `UnsnapHandler.unsnap()`

Before removing the slot, query its stored data. After removing, restore via `RestoreService`:

```swift
let stored = SnapService.shared.storedSlot(key)
// ... existing removal logic ...
if let stored { RestoreService.restore(stored, element: axWindow) }
```

### 10. Call `RestoreService` in `UnsnapHandler.unsnapAll()`

`removeVisibleRoot()` already returns full `WindowSlot` values including pre-snap data. Use `ResizeObserver.elements` to get AX handles:

```swift
let elements = ResizeObserver.shared.elements
for key in removed {
    if let ax = elements[key] { RestoreService.restore(key, element: ax) }
    // existing cleanup...
}
```

---

## Key Technical Notes

- `preSnapOrigin` uses AX coordinates (top-left screen origin), matching `readOrigin(of:)`.
- Pre-snap values are `nil` for identity-only keys (lookup stubs) — this is correct; only tree-stored slots carry them.
- During swap, pre-snap values travel with `(pid, windowHash)`, not with the tree position. This ensures unsnapping after a swap restores to each window's own original frame.
- Cross-root migration must preserve pre-snap values from the existing slot, not re-read the current (tiled) frame.
- The sentinel in three-pass swap has `nil` pre-snap values — this is fine since the sentinel is ephemeral and gets replaced in pass 3.

---

## Verification

1. Snap a window → unsnap it → it returns to its original position and size
2. Snap two windows → swap them → unsnap each → each returns to its own original frame
3. Snap two windows → drag-move one adjacent to the other → unsnap → original frame restored
4. Organize (snap all) → unsnap one → it restores; unsnapAll → all restore
5. Cross-root migration: snap on screen A, then snap again when screen B is active → unsnap → original (screen A) frame restored
