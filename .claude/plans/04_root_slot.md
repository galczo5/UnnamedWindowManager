# Plan: 04_root_slot — RootSlot, ID tracking, HorizontalSlot / VerticalSlot

## Checklist

### Phase 1 — complete
- [x] Rename `ManagedSlot` → `Slot` in `ManagedTypes.swift` (type definition + `SlotContent`)
- [x] Rename `ManagedSlot` → `Slot` in all other files
- [x] Add `id: UUID` and `parentId: UUID` to `Slot`
- [x] Add `RootSlot` struct with `id: UUID` (no `parentId`) to `ManagedTypes.swift`
- [x] Change `ManagedSlotRegistry.root` from `Slot` to `RootSlot`; update `initialize(screen:)` and `init`
- [x] Add `RootSlot` overloads for all tree helpers in `ManagedSlotRegistry.swift`
- [x] Update `extractAndWrap` to set `id`/`parentId` correctly on new container and children
- [x] Update `removeFromTree` collapse branch to propagate `parentId` to surviving child
- [x] Update `snap` to assign `id = UUID()` and `parentId = root.id` on new leaf
- [x] Update all call sites to use root overloads; change `snapshotRoot()` return type to `RootSlot`
- [x] Add `RootSlot` overload for `applyLayout` in `SnapLayout.swift`
- [x] Update `swap` in `ManagedSlotRegistry+SlotMutations.swift` to use `root.children` directly

### Phase 2 — HorizontalSlot / VerticalSlot
- [x] Remove `Slot` struct, `SlotContent` enum from `ManagedTypes.swift`; keep `Orientation` for `RootSlot`
- [x] Add `WindowSlot`, `HorizontalSlot`, `VerticalSlot` structs to `ManagedTypes.swift`
- [x] Add `indirect enum Slot` with `.window`, `.horizontal`, `.vertical` cases
- [x] Add `Slot` extension with computed `id`, `parentId` (get+set), `width`, `height` properties
- [x] Rewrite `recomputeSizes(inout Slot, ...)` in `ManagedSlotRegistry.swift` to switch on `Slot`
- [x] Rewrite `collectLeaves`, `findLeafSlot`, `maxLeafOrder` to switch on `Slot`
- [x] Rewrite `removeFromTree` to switch on `Slot`; propagate `parentId` via computed setter
- [x] Rewrite `extractAndWrap` to build `.horizontal` or `.vertical` container from orientation
- [x] Rewrite `updateLeaf` — closure now takes `inout WindowSlot`; update `setWidth` call site
- [x] Update `snap` new leaf to `Slot.window(WindowSlot(...))`
- [x] Rewrite `applyLayout(Slot, ...)` in `SnapLayout.swift` to switch on `Slot`
- [x] Update `allLeaves()` usages in `WindowSnapper.swift` and `ResizeObserver+Reapply.swift` — `leaf.content` → `case .window(let w) = leaf`
- [x] Update `replaceWindowInLeaf` in `ManagedSlotRegistry+SlotMutations.swift` to switch on `Slot`
- [x] Update `findSwapTarget` in `SnapLayout.swift` — access `w.window` instead of `leaf.content`

---

## Context / Problem

### Phase 1 (done)
Introduced `RootSlot` (cannot be nested, always screen-sized), renamed `ManagedSlot` → `Slot`,
and added `id`/`parentId` to every slot for future identity-based features.

### Phase 2
The old `Slot` type encodes orientation as a runtime property (`orientation: Orientation`).
Two container slots with different orientations are the same type, making it impossible to
distinguish them statically and requiring an extra `switch slot.content` + `slot.orientation`
double-dispatch at every call site.

The goal is to replace the single `Slot` struct + `SlotContent` enum pair with three concrete
structs (`WindowSlot`, `HorizontalSlot`, `VerticalSlot`) and a unified `Slot` enum. Orientation
becomes a compile-time property of the type rather than a runtime field. All pattern matching
collapses from a double switch into a single switch on `Slot`.

---

## Phase 2 Type Design

```swift
struct WindowSlot {
    var id: UUID
    var parentId: UUID
    var order: Int              // insertion index; used for "last added" tracking
    var width: CGFloat
    var height: CGFloat
    var window: ManagedWindow
    var gaps: Bool = true
}

struct HorizontalSlot {
    var id: UUID
    var parentId: UUID
    var width: CGFloat
    var height: CGFloat
    var children: [Slot]
    var gaps: Bool = false
}

struct VerticalSlot {
    var id: UUID
    var parentId: UUID
    var width: CGFloat
    var height: CGFloat
    var children: [Slot]
    var gaps: Bool = false
}

/// Unified slot type for tree traversal. `indirect` breaks the recursive size cycle.
indirect enum Slot {
    case window(WindowSlot)
    case horizontal(HorizontalSlot)
    case vertical(VerticalSlot)
}
```

`Orientation` enum is retained — `RootSlot` still uses it. `SlotContent` is deleted.

`RootSlot` is unchanged except `children: [Slot]` now contains the new `Slot` enum.

---

## Phase 2 Files to modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Model/ManagedTypes.swift` | Delete `Slot` struct + `SlotContent`; add `WindowSlot`, `HorizontalSlot`, `VerticalSlot`, `indirect enum Slot`, `Slot` extension |
| `UnnamedWindowManager/Model/ManagedSlotRegistry.swift` | Rewrite all tree helpers to switch on `Slot` enum |
| `UnnamedWindowManager/Model/ManagedSlotRegistry+SlotMutations.swift` | Rewrite `replaceWindowInLeaf` to switch on `Slot` |
| `UnnamedWindowManager/Snapping/SnapLayout.swift` | Rewrite `applyLayout(Slot, ...)` and `findSwapTarget` |
| `UnnamedWindowManager/Snapping/WindowSnapper.swift` | Update `leaf.content` → `case .window(let w) = leaf` |
| `UnnamedWindowManager/Observation/ResizeObserver+Reapply.swift` | Update `leaf.content` → `case .window(let w) = leaf` |

---

## Phase 2 Implementation Steps

### 1. Update `ManagedTypes.swift`

Delete `Slot` struct and `SlotContent` enum. Add the three concrete structs and the
`indirect enum Slot`. Add a `Slot` extension with computed properties for fields that
are accessed generically across all cases:

```swift
extension Slot {
    var id: UUID {
        switch self {
        case .window(let w):     return w.id
        case .horizontal(let h): return h.id
        case .vertical(let v):   return v.id
        }
    }

    var parentId: UUID {
        get {
            switch self {
            case .window(let w):     return w.parentId
            case .horizontal(let h): return h.parentId
            case .vertical(let v):   return v.parentId
            }
        }
        set {
            switch self {
            case .window(var w):     w.parentId = newValue; self = .window(w)
            case .horizontal(var h): h.parentId = newValue; self = .horizontal(h)
            case .vertical(var v):   v.parentId = newValue; self = .vertical(v)
            }
        }
    }

    var width: CGFloat {
        switch self {
        case .window(let w):     return w.width
        case .horizontal(let h): return h.width
        case .vertical(let v):   return v.width
        }
    }

    var height: CGFloat {
        switch self {
        case .window(let w):     return w.height
        case .horizontal(let h): return h.height
        case .vertical(let v):   return v.height
        }
    }
}
```

### 2. Rewrite tree helpers in `ManagedSlotRegistry.swift`

**`recomputeSizes(_ slot: inout Slot, ...)`** — single switch, no `slot.content` or `slot.orientation`:

```swift
func recomputeSizes(_ slot: inout Slot, width: CGFloat, height: CGFloat) {
    switch slot {
    case .window(var w):
        w.width = width; w.height = height
        slot = .window(w)
    case .horizontal(var h):
        h.width = width; h.height = height
        let n = CGFloat(h.children.count)
        for i in h.children.indices {
            recomputeSizes(&h.children[i], width: width / n, height: height)
        }
        slot = .horizontal(h)
    case .vertical(var v):
        v.width = width; v.height = height
        let n = CGFloat(v.children.count)
        for i in v.children.indices {
            recomputeSizes(&v.children[i], width: width, height: height / n)
        }
        slot = .vertical(v)
    }
}
```

**`removeFromTree`** — access children directly from the matched case; use computed `parentId` setter on collapse:

```swift
private func removeFromTree(_ key: ManagedWindow, slot: Slot) -> (slot: Slot?, found: Bool) {
    switch slot {
    case .window(let w):
        return w.window == key ? (nil, true) : (slot, false)
    case .horizontal(let h):
        return removeChildren(key, from: h, rebuild: { .horizontal($0) })
    case .vertical(let v):
        return removeChildren(key, from: v, rebuild: { .vertical($0) })
    }
}

// Generic helper for HorizontalSlot / VerticalSlot (both have the same children layout).
// `C` is HorizontalSlot or VerticalSlot; `rebuild` wraps the updated value back into Slot.
private func removeChildren<C: ChildContainer>(
    _ key: ManagedWindow, from container: C,
    rebuild: (C) -> Slot
) -> (slot: Slot?, found: Bool) {
    var found = false
    let newChildren: [Slot] = container.children.compactMap {
        let (s, wasFound) = removeFromTree(key, slot: $0)
        if wasFound { found = true }
        return s
    }
    guard found else { return (rebuild(container), false) }
    if newChildren.isEmpty { return (nil, true) }
    if newChildren.count == 1 {
        var child = newChildren[0]
        child.parentId = container.parentId   // skip collapsed container
        return (child, true)
    }
    var updated = container
    updated.children = newChildren
    return (rebuild(updated), true)
}
```

> `ChildContainer` is a small internal protocol with `var parentId: UUID` and
> `var children: [Slot]` that both `HorizontalSlot` and `VerticalSlot` conform to,
> avoiding the repeated code. If the protocol feels like over-engineering, inline the
> `horizontal`/`vertical` cases separately — they are identical bar the `rebuild` closure.

**`extractAndWrap`** — builds `.horizontal` or `.vertical` based on the orientation argument:

```swift
@discardableResult
private func extractAndWrap(
    _ slot: inout Slot,
    targetOrder: Int,
    newLeaf: Slot,
    orientation: Orientation
) -> Bool {
    if case .window(let w) = slot, w.order == targetOrder {
        let containerId = UUID()
        var existing = slot;  existing.parentId = containerId
        var wrapped  = newLeaf; wrapped.parentId = containerId
        let container: Slot = orientation == .horizontal
            ? .horizontal(HorizontalSlot(id: containerId, parentId: slot.parentId,
                                         width: 0, height: 0, children: [existing, wrapped]))
            : .vertical(VerticalSlot(id: containerId, parentId: slot.parentId,
                                      width: 0, height: 0, children: [existing, wrapped]))
        slot = container
        return true
    }
    switch slot {
    case .window: return false
    case .horizontal(var h):
        for i in h.children.indices {
            if extractAndWrap(&h.children[i], targetOrder: targetOrder,
                              newLeaf: newLeaf, orientation: orientation) {
                slot = .horizontal(h); return true
            }
        }
        return false
    case .vertical(var v):
        for i in v.children.indices {
            if extractAndWrap(&v.children[i], targetOrder: targetOrder,
                              newLeaf: newLeaf, orientation: orientation) {
                slot = .vertical(v); return true
            }
        }
        return false
    }
}
```

**`updateLeaf`** — closure now operates on `inout WindowSlot` directly:

```swift
@discardableResult
private func updateLeaf(
    _ key: ManagedWindow,
    in slot: inout Slot,
    update: (inout WindowSlot) -> Void
) -> Bool {
    switch slot {
    case .window(var w):
        guard w.window == key else { return false }
        update(&w); slot = .window(w); return true
    case .horizontal(var h):
        for i in h.children.indices {
            if updateLeaf(key, in: &h.children[i], update: update) {
                slot = .horizontal(h); return true
            }
        }
        return false
    case .vertical(var v):
        for i in v.children.indices {
            if updateLeaf(key, in: &v.children[i], update: update) {
                slot = .vertical(v); return true
            }
        }
        return false
    }
}
```

`setWidth` call site changes from `slot.content` mutation to:

```swift
self.updateLeaf(key, in: &self.root) { w in
    w.width = clamped
    w.window.width = clamped
}
```

**`snap`** new leaf construction:

```swift
let newLeaf = Slot.window(WindowSlot(
    id: UUID(),
    parentId: self.root.id,
    order: self.windowCount,
    width: 0, height: 0,
    window: ManagedWindow(pid: key.pid, windowHash: key.windowHash, height: 0, width: 0),
    gaps: true
))
```

### 3. Rewrite `applyLayout(Slot, ...)` in `SnapLayout.swift`

```swift
private static func applyLayout(
    _ slot: Slot,
    origin: CGPoint,
    elements: [ManagedWindow: AXUIElement]
) {
    switch slot {
    case .window(let w):
        guard let ax = elements[w.window] else { return }
        let g = w.gaps ? Config.gap : 0
        var pos  = CGPoint(x: origin.x + g, y: origin.y + g)
        var size = CGSize(width: w.width - g * 2, height: w.height - g * 2)
        Logger.shared.log("key=\(w.window.windowHash) origin=(\(Int(pos.x)),\(Int(pos.y))) size=(\(Int(size.width))×\(Int(size.height)))")
        if let posVal = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, sizeVal)
        }
    case .horizontal(let h):
        var cursor = origin
        for child in h.children {
            applyLayout(child, origin: cursor, elements: elements)
            cursor.x += child.width
        }
    case .vertical(let v):
        var cursor = origin
        for child in v.children {
            applyLayout(child, origin: cursor, elements: elements)
            cursor.y += child.height
        }
    }
}
```

`findSwapTarget` changes `leaf.content` match to:
```swift
guard case .window(let w) = leaf, w.window != draggedKey else { continue }
guard let axElement = elements[w.window], ...
```

### 4. Update `allLeaves()` usages in `WindowSnapper.swift` and `ResizeObserver+Reapply.swift`

Old: `if case .window(let w) = leaf.content { return w }`
New: `if case .window(let w) = leaf { return w.window }`

### 5. Rewrite `replaceWindowInLeaf` in `ManagedSlotRegistry+SlotMutations.swift`

```swift
@discardableResult
private func replaceWindowInLeaf(
    _ slot: inout Slot,
    target: ManagedWindow,
    with replacement: ManagedWindow
) -> Bool {
    switch slot {
    case .window(var w):
        guard w.window == target else { return false }
        w.window = replacement; slot = .window(w); return true
    case .horizontal(var h):
        for i in h.children.indices {
            if replaceWindowInLeaf(&h.children[i], target: target, with: replacement) {
                slot = .horizontal(h); return true
            }
        }
        return false
    case .vertical(var v):
        for i in v.children.indices {
            if replaceWindowInLeaf(&v.children[i], target: target, with: replacement) {
                slot = .vertical(v); return true
            }
        }
        return false
    }
}
```

---

## Key Technical Notes

- `indirect enum Slot` breaks the recursive size cycle: `HorizontalSlot.children: [Slot]` where `Slot` contains `HorizontalSlot`. The `indirect` causes the enum's associated values to be heap-allocated, giving the enum a fixed pointer size.
- `Orientation` enum is kept solely for `RootSlot`. All child slots encode orientation in their type. Container slots have no `order` field — `order` is meaningful only on `WindowSlot`.
- The computed `parentId` setter on `Slot` is the canonical way to update parent references during tree mutations (`extractAndWrap`, `removeFromTree` collapse). Avoid reaching into the associated values directly elsewhere.
- When extracting from `slot.parentId` in `extractAndWrap` before overwriting `slot`, read `slot.parentId` into a local constant first — the assignment `slot = container` overwrites the original value.
- `ChildContainer` protocol (if used): keep it `fileprivate` inside `ManagedSlotRegistry.swift`. If it causes complexity, duplicate the `horizontal`/`vertical` cases — they are short.
- `WindowSnapper.managedWindow(for:pid:)` returns `ManagedWindow`. After Phase 2, `allLeaves()` elements are `Slot` values; extract with `case .window(let w) = leaf` and use `w.window` for the `ManagedWindow`.
- `ManagedWindow` is unchanged — it remains the identity key used in `ResizeObserver.elements`.

---

## Verification

### Phase 1
1. Build succeeds with no errors.
2. Snap W1 → fills screen; leaf `parentId == root.id`.
3. Snap W2 → container wraps both; `parentId` chain correct.
4. Close W2 → collapse propagates `parentId`; W1 expands to full screen.
5. Swap W1 ↔ W2 → positions exchange; IDs unchanged.

### Phase 2 (additional)
1. Build succeeds — no `SlotContent` or `Slot` struct references remain.
2. Snap W1 → `allLeaves()` returns `[Slot.window(w)]`; `case .window(let w) = leaf` succeeds.
3. Snap W2 → tree root children contain `.vertical(VerticalSlot(...))` wrapping both leaves.
4. Snap W3 → inner container is `.horizontal(HorizontalSlot(...))`.
5. Resize W1 → `setWidth` reaches `WindowSlot`; `w.window.width` updated correctly.
6. Swap W1 ↔ W2 → `replaceWindowInLeaf` reaches `.window` case; `w.window` updated.
7. Temporarily add a `HorizontalSlot` to `RootSlot.children` as a `Slot` value → compiles (it is a valid `Slot.horizontal`). Attempting to pass a `RootSlot` as a `Slot` → compile error (they are distinct types).
