# Plan: 09_new_model_structure — Container / Slot / Window Model

## Checklist

- [x] Replace `SnapKey` with `SnapWindow`, remove `SnapEntry`, add `SlotWindow`, `SnapSlot` in `SnapTypes.swift`
- [x] Rewrite `SnapRegistry.swift` — `slots: [SnapSlot]` array with `allSlots`, `findWindow`, `slotIndex`, `register`, `remove`, `setHeight`, `setWidth`
- [x] Rewrite `SnapRegistry+SlotMutations.swift` — `moveSlot`, `swapSlots`, `swapWindowsInSlot`, `splitVertical`, `normalizeSlots`
- [x] Rewrite `SnapLayout.swift` — `applyPosition`, `findDropTarget`, `xRange`, overlay frame helpers all use `[SnapSlot]` and slot indices
- [x] Update `WindowSnapper.swift` — `snapWindow()`, `reapplyAll()` iterates slots, `register` without slot param
- [x] Update `ResizeObserver.swift` — `SnapKey` → `SnapWindow` in all maps
- [x] Update `ResizeObserver+Reapply.swift` — new `DropTarget` (slotIndex), new registry methods
- [x] Update `ResizeObserver+SwapOverlay.swift` — new overlay helper signatures
- [x] Update `UnnamedWindowManagerApp.swift` — Debug iterates slots

---

## Context

The flat `[SnapKey: SnapEntry]` model required brittle `slot`/`row` bookkeeping for vertical splits. This refactor replaces it with a hierarchical model:

```
SnapRegistry
  └─ [SnapSlot]          ← ordered left-to-right; array index IS position
       ├─ width: CGFloat
       └─ [SlotWindow]   ← ordered top-to-bottom
            ├─ key: SnapWindow
            └─ height: CGFloat
```

- `SnapKey` renamed to `SnapWindow`
- `SnapEntry` removed entirely (no more `slot`/`row` fields)
- Slot ordering = array position (no reindexing needed)
- Window stacking = array position within slot
- Drop zones target slots by index, not individual windows
