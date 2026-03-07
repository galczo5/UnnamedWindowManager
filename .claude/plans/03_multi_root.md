# Plan: 10_multi_root — Multiple Independent Tiling Roots

## Checklist

- [x] Refactor `SharedRootStore` to hold `[UUID: RootSlot]` and per-root window counts
- [x] Add `visibleRootID()` helper to `SnapService` (CGWindowList-based detection)
- [x] Rewrite `SnapService.snap()` with cross-root routing and idempotency
- [x] Update `SnapService.remove/removeAndReflow` to find root by key and destroy when empty
- [x] Update `SnapService.resize/swap/flipParentOrientation/insertAdjacent` to find root by key
- [x] Update `SnapService.isTracked/allLeaves` to scan all roots
- [x] Remove `isTracked` guard from `SnapHandler.snap()` and `SnapHandler.snapLeft()` (snap is now idempotent)
- [x] Remove `isTracked` guard from `OrganizeHandler.organize()` (same reason)
- [x] Update `LayoutService.applyLayout(screen:)` to apply layout for every root
- [x] Update `OrientFlipHandler.parentOrientation()` to use `SnapService` instead of direct store access
- [x] Update `WindowLister.logSlotTree()` to iterate all roots
- [x] Remove `SharedRootStore.initialize(screen:)` call from `UnnamedWindowManagerApp.init()`

---

## Context / Problem

Currently the app stores a single `RootSlot` in `SharedRootStore`. This means all snapped windows share one tiling layout regardless of which macOS Space they are on.

The goal is to support multiple independent roots — one per macOS Space (or any other context where no previously-snapped window is visible on screen). A new root is created on first snap when no snapped window is visible. A root is destroyed when its last window is removed. If a tracked window is moved to a different space and snapped there, it is migrated from its old root to the new one.

---

## Visibility Detection

`CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` already filters by the currently visible macOS Space. Windows on other Spaces are absent from this list. `kCGWindowNumber` in the returned dict equals the `CGWindowID` used as `windowHash` in `WindowSlot` (see `windowSlot(for:pid:)` in `AXHelpers.swift`), so a direct `Set<UInt>` membership check correlates CG windows with tracked slots.

---

## Behaviour Spec

| Situation | Result |
|-----------|--------|
| Snap, no visible snapped windows | Create new root, add window |
| Snap, some visible snapped windows | Add to the root that owns those windows |
| Snap, window already in correct root | No-op |
| Snap, window tracked in a different root | Remove from old root (destroy if empty), add to new root |
| Unsnap / window destroyed | Remove from its root; destroy root if it becomes empty |
| Organize | Same routing as snap — all visible untracked windows go into the correct root |

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Services/SharedRootStore.swift` | Modify — `root`→`roots`, `windowCount`→`windowCounts` |
| `UnnamedWindowManager/Services/SnapService.swift` | Modify — multi-root routing throughout |
| `UnnamedWindowManager/System/LayoutService.swift` | Modify — apply layout for all roots |
| `UnnamedWindowManager/System/SnapHandler.swift` | Modify — remove `isTracked` guard |
| `UnnamedWindowManager/System/OrganizeHandler.swift` | Modify — remove `isTracked` guard |
| `UnnamedWindowManager/System/OrientFlipHandler.swift` | Modify — route through `SnapService` |
| `UnnamedWindowManager/System/WindowLister.swift` | Modify — iterate all roots |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — remove `initialize(screen:)` call |

---

## Implementation Steps

### 1. Refactor `SharedRootStore`

Replace the single `root`/`windowCount` pair with dictionaries keyed by root UUID.

```swift
final class SharedRootStore {
    static let shared = SharedRootStore()
    private init() {}

    var roots: [UUID: RootSlot] = [:]
    /// Per-root insertion counter used to assign `WindowSlot.order`.
    var windowCounts: [UUID: Int] = [:]
    let queue = DispatchQueue(label: "snap.registry", attributes: .concurrent)

    func snapshotAllRoots() -> [UUID: RootSlot] {
        queue.sync { roots }
    }

    func snapshotRoot(id: UUID) -> RootSlot? {
        queue.sync { roots[id] }
    }
}
```

Remove `initialize(screen:)` and `windowCount`. Remove the call to `initialize` from `UnnamedWindowManagerApp.init()`.

### 2. Add `visibleRootID()` to `SnapService`

Called from within a barrier block; safe to invoke CGWindowList from a background queue.

```swift
/// Must be called inside a store.queue barrier block.
private func visibleRootID() -> UUID? {
    let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
    guard let cgList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return nil }

    var visibleHashes = Set<UInt>()
    for info in cgList {
        guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let pid   = info[kCGWindowOwnerPID as String] as? Int,
              let wid   = info[kCGWindowNumber as String] as? CGWindowID,
              pid_t(pid) != ownPID
        else { continue }
        visibleHashes.insert(UInt(wid))
    }

    for (rootID, root) in store.roots {
        for leaf in tree.allLeaves(in: root) {
            if case .window(let w) = leaf, visibleHashes.contains(w.windowHash) {
                return rootID
            }
        }
    }
    return nil
}
```

### 3. Rewrite `SnapService.snap()`

```swift
func snap(_ key: WindowSlot, screen: NSScreen) {
    store.queue.sync(flags: .barrier) {
        // Determine target root before any mutation.
        let targetRootID = visibleRootID() ?? {
            let id = UUID()
            let f  = screen.visibleFrame
            store.roots[id] = RootSlot(id: id, width: f.width, height: f.height,
                                       orientation: .horizontal, children: [])
            return id
        }()

        // If already in target root, nothing to do.
        if tree.isTracked(key, in: store.roots[targetRootID]!) { return }

        // Remove from old root (cross-root move), destroy if empty.
        if let srcID = store.roots.keys.first(where: { tree.isTracked(key, in: store.roots[$0]!) }) {
            tree.removeLeaf(key, from: &store.roots[srcID]!)
            if store.roots[srcID]!.children.isEmpty {
                store.roots.removeValue(forKey: srcID)
                store.windowCounts.removeValue(forKey: srcID)
            }
        }

        // Insert into target root.
        store.windowCounts[targetRootID, default: 0] += 1
        let order = store.windowCounts[targetRootID]!
        let newLeaf = Slot.window(WindowSlot(
            pid: key.pid, windowHash: key.windowHash,
            id: UUID(), parentId: store.roots[targetRootID]!.id,
            order: order, width: 0, height: 0, gaps: true
        ))
        if store.roots[targetRootID]!.children.isEmpty {
            store.roots[targetRootID]!.children = [newLeaf]
        } else {
            let lastOrder = tree.maxLeafOrder(in: store.roots[targetRootID]!)
            let orientation: Orientation = order % 2 == 0 ? .horizontal : .vertical
            tree.extractAndWrap(in: &store.roots[targetRootID]!, targetOrder: lastOrder,
                                newLeaf: newLeaf, orientation: orientation)
        }
        position.recomputeSizes(&store.roots[targetRootID]!,
                                width: screen.visibleFrame.width  - Config.gap * 2,
                                height: screen.visibleFrame.height - Config.gap * 2)
    }
}
```

### 4. Update remaining `SnapService` methods

All methods that previously operated on `store.root` now locate the root by key first:

```swift
private func rootID(containing key: WindowSlot) -> UUID? {
    store.roots.keys.first { tree.isTracked(key, in: store.roots[$0]!) }
}
```

- **`isTracked`**: `store.roots.values.contains { tree.isTracked(key, in: $0) }`
- **`allLeaves`**: `store.roots.values.flatMap { tree.allLeaves(in: $0) }.sorted { ... }`
- **`removeAndReflow`**: find root, remove, destroy if empty, else recompute
- **`remove`**: same but async, no recompute
- **`resize/swap/flipParentOrientation/insertAdjacent`**: find the relevant root(s), operate on it

For `insertAdjacent` (drag-to-reorder): target and dragged may come from different roots. Remove dragged from its old root (destroy if empty), then insert adjacent to target in target's root.

### 5. Remove `isTracked` guards from callers

`SnapService.snap()` is now idempotent (no-op if already in correct root, moves if in wrong root). Remove the `guard !SnapService.shared.isTracked(key) else { return }` / `continue` from:
- `SnapHandler.snap()`
- `SnapHandler.snapLeft()`
- `OrganizeHandler.organize()`

### 6. Update `LayoutService.applyLayout(screen:)`

```swift
func applyLayout(screen: NSScreen) {
    let visible       = screen.visibleFrame
    let primaryHeight = NSScreen.screens[0].frame.height
    let origin = CGPoint(x: visible.minX + Config.gap, y: primaryHeight - visible.maxY + Config.gap)
    let elements = ResizeObserver.shared.elements
    let roots = SharedRootStore.shared.snapshotAllRoots()
    for root in roots.values {
        applyLayout(root, origin: origin, elements: elements)
    }
}
```

Each root covers the full screen; windows on other Spaces are simply not visible to the user even though AX positions them correctly.

### 7. Update `OrientFlipHandler.parentOrientation()`

Replace the direct `store.root` access with a `SnapService` call. Add to `SnapService`:

```swift
func parentOrientation(of key: WindowSlot) -> Orientation? {
    store.queue.sync {
        guard let id = rootID(containing: key) else { return nil }
        return tree.findParentOrientation(of: key, in: store.roots[id]!)
    }
}
```

Then `OrientFlipHandler.parentOrientation()` calls `SnapService.shared.parentOrientation(of: key)`.

### 8. Update `WindowLister.logSlotTree()`

```swift
static func logSlotTree() {
    let roots = SharedRootStore.shared.snapshotAllRoots()
    Logger.shared.log("=== Slot trees (\(roots.count) roots) ===")
    for (id, root) in roots.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
        Logger.shared.log("root \(id.uuidString.prefix(8))  size=\(root.width)x\(root.height)  orientation=\(root.orientation)  children=\(root.children.count)")
        for child in root.children { logSlot(child, depth: 1) }
    }
    Logger.shared.log("=== End of slot trees ===")
}
```

---

## Key Technical Notes

- `windowHash` equals `CGWindowID` cast to `UInt` (set in `windowSlot(for:pid:)` via `_AXUIElementGetWindow`). `kCGWindowNumber` in `CGWindowListCopyWindowInfo` results is the same `CGWindowID`. The visibility check is a direct `Set<UInt>` lookup — no AX round-trip needed.
- `visibleRootID()` must be called inside the barrier block so it sees a consistent snapshot of `store.roots`. CGWindowList is safe to call from any thread.
- When a root is destroyed, its `windowCounts` entry must also be removed to avoid stale counters if a new root is created with the same UUID (UUID collision is astronomically unlikely, but correct cleanup is required).
- `allLeaves()` aggregates from all roots. The sorted order by `order` is per-root sequential, not globally meaningful, but it is only used for swap-overlay rendering order — which remains visually correct.
- `insertAdjacent` (drag-and-drop reorder) must handle the cross-root case: dragged window removed from its source root (destroyed if empty), inserted into target's root.
- The `initialize(screen:)` removal means the store starts with zero roots. The first `snap()` call creates the first root lazily from the screen frame.
- Layout is applied to all roots on every `reapplyAll()`. Windows on other Spaces receive correct AX positions even though they are invisible — this is harmless and ensures correct layout when switching back.

---

## Verification

1. Cold start: snap two windows → both appear side-by-side in one root. Debug menu shows one root with two leaves.
2. Switch to a new macOS Space (Cmd+Ctrl+→), snap a window → Debug shows a second root with one leaf; the first root is unchanged.
3. Switch back to Space 1 → layout is intact.
4. Move a window from Space 1 to Space 2, then snap it → Debug shows it removed from Root 1 and added to Root 2. Root 1 now has one window; if only one window was in Root 1 it gets destroyed (verify Debug shows one root).
5. Unsnap the last window in a root → root is destroyed; Debug shows one fewer root.
6. Organize on a Space with no snapped windows → creates a new root with all visible windows.
7. Organize on a Space with some snapped windows already present → all visible untracked windows snap into the existing root (no duplicate roots created).
