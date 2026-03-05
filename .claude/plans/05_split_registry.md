# Plan: 05_split_registry — Split ManagedSlotRegistry into focused services

## Checklist

- [x] Create `SharedRootStore.swift` with root state, queue, initialize, snapshotRoot
- [x] Create `SlotTreeService.swift` with all tree structural operations
- [x] Create `PositionService.swift` with recomputeSizes overloads and setWidth
- [x] Create `SnapService.swift` with snap, removeAndReflow, isTracked, allLeaves, remove, swap
- [x] Delete `ManagedSlotRegistry.swift`
- [x] Delete `ManagedSlotRegistry+SlotMutations.swift`
- [x] Update `UnnamedWindowManagerApp.swift` — `SharedRootStore.shared.initialize`
- [x] Update `WindowSnapper.swift` — `SnapService.shared.*`
- [x] Update `SnapLayout.swift` — `SharedRootStore.shared.snapshotRoot()` + `SnapService.shared.allLeaves()`
- [x] Update `ResizeObserver.swift` — `SnapService.shared.*`
- [x] Update `ResizeObserver+Reapply.swift` — `SnapService.shared.*`

---

## Context / Problem

`ManagedSlotRegistry` is a 330-line monolith that owns state, tree traversal, size computation, and snap orchestration in one class. Callers across multiple files reach into it for unrelated concerns. The goal is to separate responsibilities so each service has a single reason to change:

- **SharedRootStore** — owns the mutable tree state and the concurrent queue
- **SlotTreeService** — all structural tree mutations (insert, remove, swap, find, collect)
- **PositionService** — size propagation and width overrides
- **SnapService** — high-level orchestration; becomes the new public call site replacing `ManagedSlotRegistry.shared`

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Model/SharedRootStore.swift` | **New file** — mutable state: root, windowCount, queue, initialize, snapshotRoot |
| `UnnamedWindowManager/Model/SlotTreeService.swift` | **New file** — all tree traversal and structural mutations |
| `UnnamedWindowManager/Model/PositionService.swift` | **New file** — recomputeSizes (RootSlot + Slot overloads), setWidth logic |
| `UnnamedWindowManager/Model/SnapService.swift` | **New file** — snap, removeAndReflow, isTracked, allLeaves, remove, swap; public singleton |
| `UnnamedWindowManager/Model/ManagedSlotRegistry.swift` | **Delete** |
| `UnnamedWindowManager/Model/ManagedSlotRegistry+SlotMutations.swift` | **Delete** |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — call `SharedRootStore.shared.initialize` |
| `UnnamedWindowManager/Snapping/WindowSnapper.swift` | Modify — replace `ManagedSlotRegistry.shared` with `SnapService.shared` |
| `UnnamedWindowManager/Snapping/SnapLayout.swift` | Modify — `snapshotRoot()` from `SharedRootStore`, `allLeaves()` from `SnapService` |
| `UnnamedWindowManager/Observation/ResizeObserver.swift` | Modify — replace `ManagedSlotRegistry.shared` with `SnapService.shared` |
| `UnnamedWindowManager/Observation/ResizeObserver+Reapply.swift` | Modify — replace `ManagedSlotRegistry.shared` with `SnapService.shared` |

---

## Implementation Steps

### 1. Create SharedRootStore

Owns the mutable tree and the barrier queue. All other services receive it as a parameter or access it via the singleton.

```swift
final class SharedRootStore {
    static let shared = SharedRootStore()
    private init() {
        root = RootSlot(id: UUID(), width: 0, height: 0,
                        orientation: .vertical, children: [])
    }

    var root: RootSlot
    var windowCount: Int = 0
    let queue = DispatchQueue(label: "snap.registry", attributes: .concurrent)

    func initialize(screen: NSScreen) {
        let f = screen.visibleFrame
        queue.sync(flags: .barrier) {
            self.root = RootSlot(id: UUID(), width: f.width, height: f.height,
                                 orientation: .horizontal, children: [])
            self.windowCount = 0
        }
    }

    func snapshotRoot() -> RootSlot {
        queue.sync { root }
    }
}
```

### 2. Create SlotTreeService

Move every private tree helper out of `ManagedSlotRegistry` and the `+SlotMutations` extension. Expose the operations that higher-level services need as `internal` methods. The service is stateless — it takes `inout RootSlot` or reads from the store.

Methods to include (signatures match existing implementations exactly):
- `isTracked(_ key:, in:) -> Bool`
- `allLeaves(in:) -> [Slot]`
- `remove(_ key:, from:)` — structural removal only, no reflow
- `swap(_ keyA:, _ keyB:, in:)` — from `+SlotMutations`
- `findLeafSlot(_ key:, in:) -> Slot?` (both overloads)
- `collectLeaves(in:) -> [Slot]` (both overloads)
- `removeLeaf(_ key:, from:) -> Bool`
- `removeFromTree(_ key:, slot:) -> (Slot?, Bool)`
- `extractAndWrap(in:, targetOrder:, newLeaf:, orientation:)` (both overloads)
- `maxLeafOrder(in:) -> Int` (both overloads)
- `updateLeaf(_ key:, in:, update:)` (both overloads)
- `replaceWindowInLeaf(_ slot:, target:, with:) -> Bool`

All of these are mechanical moves with no logic changes.

### 3. Create PositionService

Extract the two `recomputeSizes` overloads verbatim. Add the width-clamping logic from `setWidth` as a helper (`clampedWidth(_:screen:)`).

```swift
struct PositionService {
    func recomputeSizes(_ root: inout RootSlot, width: CGFloat, height: CGFloat) { ... }
    func recomputeSizes(_ slot: inout Slot, width: CGFloat, height: CGFloat) { ... }

    func clampedWidth(_ width: CGFloat, screen: NSScreen) -> CGFloat {
        min(width, screen.visibleFrame.width * Config.maxWidthFraction)
    }
}
```

### 4. Create SnapService

The new public singleton. Coordinates store + tree + position. Replaces every `ManagedSlotRegistry.shared` call site.

```swift
final class SnapService {
    static let shared = SnapService()
    private init() {}

    private let store    = SharedRootStore.shared
    private let tree     = SlotTreeService()
    private let position = PositionService()

    func isTracked(_ key: WindowSlot) -> Bool {
        store.queue.sync { tree.isTracked(key, in: store.root) }
    }

    func allLeaves() -> [Slot] {
        store.queue.sync {
            tree.allLeaves(in: store.root).sorted { a, b in
                if case .window(let wa) = a, case .window(let wb) = b { return wa.order < wb.order }
                return false
            }
        }
    }

    func snap(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            store.windowCount += 1
            let newLeaf = Slot.window(WindowSlot(
                pid: key.pid, windowHash: key.windowHash,
                id: UUID(), parentId: store.root.id,
                order: store.windowCount,
                width: 0, height: 0, gaps: true
            ))
            if store.root.children.isEmpty {
                store.root.children = [newLeaf]
            } else {
                let lastOrder = tree.maxLeafOrder(in: store.root)
                let orientation: Orientation = store.windowCount % 2 == 0 ? .horizontal : .vertical
                tree.extractAndWrap(in: &store.root, targetOrder: lastOrder,
                                    newLeaf: newLeaf, orientation: orientation)
            }
            position.recomputeSizes(&store.root,
                                    width: screen.visibleFrame.width  - Config.gap * 2,
                                    height: screen.visibleFrame.height - Config.gap * 2)
        }
    }

    func remove(_ key: WindowSlot) {
        store.queue.async(flags: .barrier) {
            self.tree.removeLeaf(key, from: &self.store.root)
        }
    }

    func removeAndReflow(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            tree.removeLeaf(key, from: &store.root)
            position.recomputeSizes(&store.root,
                                    width: screen.visibleFrame.width  - Config.gap * 2,
                                    height: screen.visibleFrame.height - Config.gap * 2)
        }
    }

    func setWidth(_ width: CGFloat, forSlotContaining key: WindowSlot, screen: NSScreen) {
        let clamped = position.clampedWidth(width, screen: screen)
        store.queue.async(flags: .barrier) {
            self.tree.updateLeaf(key, in: &self.store.root) { w in w.width = clamped }
        }
    }

    func swap(_ keyA: WindowSlot, _ keyB: WindowSlot) {
        store.queue.sync(flags: .barrier) {
            tree.swap(keyA, keyB, in: &store.root)
        }
    }
}
```

### 5. Delete old files

Remove `ManagedSlotRegistry.swift` and `ManagedSlotRegistry+SlotMutations.swift` from the project (delete from disk and from the Xcode target).

### 6. Update callers

All five call sites replace `ManagedSlotRegistry.shared` with `SnapService.shared`, except `snapshotRoot()` and `initialize(screen:)` which move to `SharedRootStore.shared`:

| Old call | New call |
|---|---|
| `ManagedSlotRegistry.shared.initialize(screen:)` | `SharedRootStore.shared.initialize(screen:)` |
| `ManagedSlotRegistry.shared.snapshotRoot()` | `SharedRootStore.shared.snapshotRoot()` |
| `ManagedSlotRegistry.shared.snap(key, screen:)` | `SnapService.shared.snap(key, screen:)` |
| `ManagedSlotRegistry.shared.isTracked(key)` | `SnapService.shared.isTracked(key)` |
| `ManagedSlotRegistry.shared.allLeaves()` | `SnapService.shared.allLeaves()` |
| `ManagedSlotRegistry.shared.remove(key)` | `SnapService.shared.remove(key)` |
| `ManagedSlotRegistry.shared.removeAndReflow(key, screen:)` | `SnapService.shared.removeAndReflow(key, screen:)` |
| `ManagedSlotRegistry.shared.setWidth(w, forSlotContaining:, screen:)` | `SnapService.shared.setWidth(w, forSlotContaining:, screen:)` |
| `ManagedSlotRegistry.shared.swap(keyA, keyB)` | `SnapService.shared.swap(keyA, keyB)` |

---

## Key Technical Notes

- `SlotTreeService` must be a class (not struct) if it holds no state — a struct works fine since it's stateless; all methods take `inout` parameters or return values
- All barriers in `SnapService` must acquire `store.queue` — never nest a barrier inside another barrier on the same queue (deadlock)
- `replaceWindowInLeaf` is called twice per swap (A→B then B→A); this logic must be preserved exactly in `SlotTreeService.swap`
- `PositionService.recomputeSizes` overloads are recursive — the `Slot` overload calls itself; keep both in the same file
- Xcode target membership: new files must be added to the `UnnamedWindowManager` target

---

## Verification

1. Build with no errors or warnings after each new file is added
2. Snap a window → it snaps into the correct slot
3. Snap a second window → tree splits horizontally; both windows tile correctly
4. Unsnap a window → remaining window expands to fill the screen
5. Drag a snapped window onto another → they swap positions
6. Close a snapped window (cmd+Q) → it is removed and remaining windows reflow
7. Resize a snapped window → width override is stored; other windows adjust
8. Launch the app fresh → `initialize` runs without crash; first snap works
