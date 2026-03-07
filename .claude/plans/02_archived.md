# Plan: 02_archived — [ARCHIVED] Core Slot Tree Model, Services, and Features

> **Archived** — This entry consolidates plans [02 `02_slot_tree_model`, 03 `03_center_swap`, 04 `04_root_slot`, 05 `05_split_registry`, 06 `06_window_resize`, 07 `07_drop_zones`, 08 `08_resize_refusal_check`, 09 `09_flip_slot_orientation`].
> These plans have been completed and their details removed. Only key context is preserved.

---

## What This Covered

The flat `ManagedSlot` column model was replaced with a recursive `indirect enum Slot` tree (`WindowSlot`, `HorizontalSlot`, `VerticalSlot`) rooted at a distinct `RootSlot`. The monolithic `ManagedSlotRegistry` was split into `SharedRootStore` (state), `SlotTreeService` (tree mutations), `PositionService` (fraction-based size computation), `SnapService` (orchestration), and `ResizeService` (resize propagation). On top of this foundation, window swap and directional drop zones (left/right/top/bottom) were added for drag interactions, persistent proportional resizing via per-slot fractions was implemented, a post-resize refusal validator detects windows that ignore AX resize requests and corrects fractions, and a menu bar button was added to flip the orientation of the focused window's parent container.

---

## Plans Consolidated

| Original # | Name | Summary |
|---|---|---|
| 02 | `02_slot_tree_model` | Replaced flat slot array with a recursive tree; introduced `Orientation`, `SlotContent`, and `ManagedSlot` as a tree node; disabled drop zones pending redesign |
| 03 | `03_center_swap` | Re-enabled center-drop swap for the tree model; added `findSwapTarget`, `swap()`, and live blue overlay over target window |
| 04 | `04_root_slot` | Introduced `RootSlot` (screen-sized, never nested); renamed `ManagedSlot` → `Slot`; added `id`/`parentId` on all slots; replaced `Slot` struct with typed enum (`WindowSlot`, `HorizontalSlot`, `VerticalSlot`) |
| 05 | `05_split_registry` | Split `ManagedSlotRegistry` into `SharedRootStore`, `SlotTreeService`, `PositionService`, `SnapService`; deleted the registry monolith |
| 06 | `06_window_resize` | Added `fraction` field to all slot types; rewrote `recomputeSizes` to use fractions; added `ResizeService` for upward fraction propagation on drag-resize |
| 07 | `07_drop_zones` | Added `DropZone` / `DropTarget` types; implemented four directional drop zones with `insertAdjacentTo`; overlays show partial zone highlight |
| 08 | `08_resize_refusal_check` | Added `NotificationService` and `PostResizeValidator`; 300 ms after resize, checks AX-reported sizes vs slot targets and corrects fractions for refusing windows |
| 09 | `09_flip_slot_orientation` | Added `OrientFlipHandler` and `flipParentOrientation` to flip a container's orientation from the menu bar; dynamic label reflects current parent orientation |

---

## Important Files

`UnnamedWindowManager/Model/ManagedTypes.swift`
`UnnamedWindowManager/Model/SharedRootStore.swift`
`UnnamedWindowManager/Model/DropTarget.swift`
`UnnamedWindowManager/Services/SlotTreeService.swift`
`UnnamedWindowManager/Services/PositionService.swift`
`UnnamedWindowManager/Services/SnapService.swift`
`UnnamedWindowManager/Services/ResizeService.swift`
`UnnamedWindowManager/Services/NotificationService.swift`
`UnnamedWindowManager/Observation/PostResizeValidator.swift`
`UnnamedWindowManager/Observation/ResizeObserver.swift`
`UnnamedWindowManager/Observation/ResizeObserver+Reapply.swift`
`UnnamedWindowManager/Observation/ResizeObserver+SwapOverlay.swift`
`UnnamedWindowManager/Snapping/SnapLayout.swift`
`UnnamedWindowManager/Snapping/WindowSnapper.swift`
`UnnamedWindowManager/System/ReapplyHandler.swift`
`UnnamedWindowManager/System/OrientFlipHandler.swift`
`UnnamedWindowManager/UnnamedWindowManagerApp.swift`

---
