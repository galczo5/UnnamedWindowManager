# Plan: 13_scrolling_root_slot — Introduce ScrollingRootSlot and RootSlot union type

## Checklist

- [x] Create `ScrollingRootSlot.swift`
- [x] Create `RootSlot.swift` enum
- [x] Update `SharedRootStore.swift` — change roots to `[UUID: RootSlot]`
- [x] Update `TileService.swift` — unwrap `.tiling` throughout; keep public APIs unchanged
- [x] Update `WindowLister.swift` — handle `RootSlot` enum in `logSlotTree()`

---

## Context / Problem

The app currently has one root type: `TilingRootSlot`, a recursive binary-split layout. A new `ScrollingRootSlot` is needed to represent a different layout model with distinct left, right, and center zones.

`SharedRootStore.roots` is currently typed `[UUID: TilingRootSlot]`. It needs to become `[UUID: RootSlot]`, where `RootSlot` is a union of both root types. No behavioral changes: `TilingRootSlot` is still created for all tile operations; the new type simply exists structurally.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Model/ScrollingRootSlot.swift` | **New file** — defines `ScrollingRootSlot` with `left`, `right`, `center` |
| `UnnamedWindowManager/Model/RootSlot.swift` | **New file** — enum wrapping `TilingRootSlot` or `ScrollingRootSlot` |
| `UnnamedWindowManager/Services/SharedRootStore.swift` | Modify — change `roots` and snapshot methods to use `RootSlot` |
| `UnnamedWindowManager/Services/TileService.swift` | Modify — unwrap `.tiling` before passing to tree services; keep return types stable |
| `UnnamedWindowManager/System/WindowLister.swift` | Modify — switch on `RootSlot` in `logSlotTree()` |

---

## Implementation Steps

### 1. Create `ScrollingRootSlot`

A fixed-zone layout with a single slot for each of the three zones.

```swift
// The root of a scrolling layout: a single center slot flanked by left and right slots.
struct ScrollingRootSlot {
    var id: UUID
    var width: CGFloat
    var height: CGFloat
    var left: Slot
    var center: Slot
    var right: Slot
}
```

### 2. Create `RootSlot` enum

```swift
// A layout root — either a recursive tiling tree or a scrolling zone layout.
enum RootSlot {
    case tiling(TilingRootSlot)
    case scrolling(ScrollingRootSlot)

    var id: UUID {
        switch self {
        case .tiling(let r): return r.id
        case .scrolling(let r): return r.id
        }
    }
}
```

The `id` computed property lets `SharedRootStore` and `TileService` use the id without switching everywhere.

### 3. Update `SharedRootStore`

Change `roots` type and update both snapshot methods:

```swift
var roots: [UUID: RootSlot] = [:]

func snapshotAllRoots() -> [UUID: RootSlot] {
    queue.sync { roots }
}

func snapshotRoot(id: UUID) -> RootSlot? {
    queue.sync { roots[id] }
}
```

### 4. Update `TileService`

All internal methods that previously accessed `store.roots[id]!` as a `TilingRootSlot` must unwrap `.tiling`. Methods that create roots wrap them on write. Public return types (`snapshotVisibleRoot() -> TilingRootSlot?`, `leavesInVisibleRoot() -> [Slot]`) stay unchanged — they unwrap internally.

**On write** (in `snap()`):

```swift
let newRoot = TilingRootSlot(id: id, width: f.width, height: f.height,
                              orientation: .horizontal, children: [])
store.roots[id] = .tiling(newRoot)
```

**On read/mutate** — pattern for every method that touches a tiling root:

```swift
guard case .tiling(var root) = store.roots[targetRootID] else { return }
// ... mutate root ...
store.roots[targetRootID] = .tiling(root)
```

**`visibleRootID()`** — iterate only tiling roots when checking leaves:

```swift
for (id, rootSlot) in store.roots {
    guard case .tiling(let root) = rootSlot else { continue }
    for leaf in treeQuery.allLeaves(in: root) {
        if case .window(let w) = leaf, visibleHashes.contains(w.windowHash) { return id }
    }
}
```

**`rootIDSync(containing:)`**:

```swift
store.roots.first { _, rootSlot in
    guard case .tiling(let root) = rootSlot else { return false }
    return treeQuery.isTracked(key, in: root)
}?.key
```

**`isTracked()`**:

```swift
store.roots.values.contains {
    guard case .tiling(let root) = $0 else { return false }
    return treeQuery.isTracked(key, in: root)
}
```

**`snapshotVisibleRoot() -> TilingRootSlot?`** — unwrap `.tiling` and return nil for non-tiling:

```swift
guard let id = visibleRootID(), case .tiling(let root) = store.roots[id]! else { return nil }
return root
```

### 5. Update `WindowLister`

`logSlotTree()` accesses `root.width`, `root.height`, `root.orientation`, `root.children` directly — these are no longer available without unwrapping. Switch on the enum:

```swift
for (id, rootSlot) in roots.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
    switch rootSlot {
    case .tiling(let root):
        Logger.shared.log("root \(id.uuidString.prefix(8))  size=\(Int(root.width))x\(Int(root.height))  orientation=\(root.orientation)  children=\(root.children.count)")
        for child in root.children { logSlot(child, depth: 1) }
    case .scrolling(let root):
        Logger.shared.log("scrolling root \(id.uuidString.prefix(8))  size=\(Int(root.width))x\(Int(root.height))")
    }
}
```

---

## Key Technical Notes

- All existing tree services (`SlotTreeQueryService`, `SlotTreeMutationService`, `SlotTreeInsertService`, `PositionService`, `ResizeService`) take `TilingRootSlot` parameters and do not need changes — `TileService` unwraps before passing.
- `snapshotVisibleRoot() -> TilingRootSlot?` stays typed as `TilingRootSlot?` so `LayoutService`, `FocusDirectionService`, and `AutoTileObserver` require no changes.
- Every `store.roots[id]!` mutation follows a read-modify-write cycle because `TilingRootSlot` is a value type (struct): always write back with `store.roots[id] = .tiling(root)` after mutation.
- `windowCounts` keyed by root UUID is unaffected — UUID keys remain the same.

---

## Verification

1. Build succeeds with no compiler errors.
2. Tile a window → it tiles normally (TilingRootSlot created and stored as `.tiling`).
3. Tile all → OrganizeHandler runs without change; all windows tile correctly.
4. Untile → windows return to pre-tile position as before.
5. Open Debug log → `logSlotTree()` prints tiling roots with the same format as before.
