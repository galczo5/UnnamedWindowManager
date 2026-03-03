# Plan: 10_model_naming — Rename Model Types

## Checklist

- [x] Rename `SnapWindow` → `ManagedWindow` and merge `SlotWindow` into it in `SnapTypes.swift`
- [x] Rename `SnapSlot` → `ManagedSlot` in `SnapTypes.swift`
- [x] Rename `SnapRegistry` → `ManagedSlotRegistry` in `SnapRegistry.swift`
- [x] Rename file `SnapTypes.swift` → `ManagedTypes.swift`
- [x] Rename file `SnapRegistry.swift` → `ManagedSlotRegistry.swift`
- [x] Rename file `SnapRegistry+SlotMutations.swift` → `ManagedSlotRegistry+SlotMutations.swift`
- [x] Update `SnapLayout.swift` — all type references
- [x] Update `WindowSnapper.swift` — all type references
- [x] Update `ResizeObserver.swift` — all type references
- [x] Update `ResizeObserver+Reapply.swift` — all type references
- [x] Update `ResizeObserver+SwapOverlay.swift` — all type references
- [x] Update `UnnamedWindowManagerApp.swift` — all type references

---

## Renames

| Old Name       | New Name        | Reason                                      |
|----------------|-----------------|----------------------------------------------|
| `SnapWindow`   | `ManagedWindow` | Generic identity — not tied to "snapping"    |
| `SlotWindow`   | *(merged)*      | Merge into `ManagedWindow` — add `height`    |
| `SnapSlot`     | `ManagedSlot`   | Consistent with `ManagedWindow`              |
| `SnapRegistry` | `ManagedSlotRegistry` | Consistent naming, describes what it manages |

## Merge: `SlotWindow` into `ManagedWindow`

Current two-struct setup:

```swift
struct SnapWindow: Hashable, Sendable {   // identity only
    let pid: pid_t
    let windowHash: UInt
}

struct SlotWindow {                        // identity + height
    let key: SnapWindow
    var height: CGFloat
}
```

After merge — single struct:

```swift
struct ManagedWindow: Hashable, Sendable {
    let pid: pid_t
    let windowHash: UInt
    var height: CGFloat

    // Hashable/Equatable by identity only (pid + windowHash)
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && lhs.windowHash == rhs.windowHash
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(windowHash)
    }
}
```

This eliminates the `SlotWindow.key` indirection. Everywhere that currently says `slotWindow.key` becomes just `window` directly.

## Affected files

| File | Changes |
|------|---------|
| `SnapTypes.swift` → `ManagedTypes.swift` | Define `ManagedWindow`, `ManagedSlot`, keep `DropZone`/`DropTarget` unchanged |
| `SnapRegistry.swift` → `ManagedSlotRegistry.swift` | `SnapRegistry` → `ManagedSlotRegistry`, `SnapWindow` → `ManagedWindow`, `SlotWindow` → `ManagedWindow`, `SnapSlot` → `ManagedSlot` |
| `SnapRegistry+SlotMutations.swift` → `ManagedSlotRegistry+SlotMutations.swift` | Same renames in extension |
| `SnapLayout.swift` | `SnapSlot` → `ManagedSlot`, `SnapWindow` → `ManagedWindow`, `SlotWindow` → `ManagedWindow` |
| `WindowSnapper.swift` | `SnapRegistry` → `ManagedSlotRegistry`, `SnapWindow` → `ManagedWindow`, `SlotWindow` → `ManagedWindow` |
| `ResizeObserver.swift` | `SnapRegistry` → `ManagedSlotRegistry`, `SnapWindow` → `ManagedWindow` |
| `ResizeObserver+Reapply.swift` | `SnapRegistry` → `ManagedSlotRegistry`, `SnapWindow` → `ManagedWindow` |
| `ResizeObserver+SwapOverlay.swift` | `SnapRegistry` → `ManagedSlotRegistry`, `SnapWindow` → `ManagedWindow` |
| `UnnamedWindowManagerApp.swift` | `SnapRegistry` → `ManagedSlotRegistry` |

## New model hierarchy

```
ManagedSlotRegistry
  └─ [ManagedSlot]        ← ordered left-to-right
       ├─ width: CGFloat
       └─ [ManagedWindow] ← ordered top-to-bottom
            ├─ pid: pid_t
            ├─ windowHash: UInt
            └─ height: CGFloat
```
