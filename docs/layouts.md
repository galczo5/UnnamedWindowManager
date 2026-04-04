# Layouts: Tiling vs Scrolling

The window manager supports two layout modes: **Tiling** and **Scrolling**. Each mode uses a different data structure and handles operations differently.

---

## TilingRootSlot

A recursive tree of splits that covers the full screen. Each node is either a window leaf, a split container (with its own orientation and children), or a stacking group.

```
TilingRootSlot
├── orientation: .horizontal | .vertical
├── children: [Slot]
│   ├── .window(WindowSlot)
│   ├── .split(SplitSlot)   ← nested, has its own orientation + children
│   └── .stacking(StackingSlot)
└── gaps: Bool
```

Each child carries a `fraction` — its share of the parent's size along the split axis. Fractions are normalized so siblings sum to 1.0.

### Focus (left / right / up / down)

Spatial neighbor-finding. `TilingNeighborService` computes screen rects for every leaf window, filters candidates in the requested direction, then picks the nearest by overlap and distance. All four directions are supported.

### Swap (left / right / up / down)

Uses the same spatial neighbor algorithm. Once the neighbor is found, `TilingTreeInsertService.swap()` performs a three-pass replacement (source → sentinel → target → source) to safely swap two windows in different subtrees without collisions. Slot sizes and fractions stay unchanged.

### Insert

`TilingEditService.insertAdjacent()` takes a drop zone (.left / .right / .top / .bottom). If the target's parent already has the needed orientation, the new window is inserted as a sibling. Otherwise the target is wrapped in a new split container with the correct orientation. The new pair gets a 50/50 fraction split.

### Resize

When a window is resized via accessibility, `TilingResizeService` converts the reported size back to slot space, computes the delta on the axis with the larger change, and adjusts the fraction of that slot relative to its sibling. Fractions are clamped to a minimum of 0.05 and the pair is renormalized.

---

## ScrollingRootSlot

A flat three-zone layout: a **center** slot flanked by optional **left** and **right** stacking slots. The center always holds a single window (or stacking group). Side slots hold stacks of windows that "peek" partially from behind.

```
ScrollingRootSlot
├── left:  Optional<Slot>   (stacking, aligned right)
├── center: Slot            (single window or stacking)
├── right: Optional<Slot>   (stacking, aligned left)
└── centerWidthFraction: CGFloat?
```

Center width is controlled by `centerWidthFraction` (clamped to config min/max). Side slots split the remaining screen width equally (or one side takes all remaining if the other is empty).

### Focus left / right

Rotational scrolling — windows flow through the three zones:

- **Focus left (scroll left):** the last window from the LEFT stack becomes the new CENTER. The old center moves to the RIGHT stack.
- **Focus right (scroll right):** the last window from the RIGHT stack becomes the new CENTER. The old center moves to the LEFT stack.

```
scrollLeft():  left.removeLast() → center,  center → right.append()
scrollRight(): right.removeLast() → center,  center → left.append()
```

### Focus up / down

Not supported — the layout is horizontal only.

### Swap (left / right only)

Swaps the last window from one side to the other without changing slot sizes or the center:

- **Swap left:** last window from LEFT moves to RIGHT.
- **Swap right:** last window from RIGHT moves to LEFT.

Up/down swaps are not supported.

### Insert

`addWindow()` pushes the current center into the left stack and places the new window as the center. Removal promotes from the left stack first, then the right if left is empty.

### Resize

Only the center window is resizable. `ScrollingResizeService` updates `centerWidthFraction` based on the new width. Side slots adjust their widths accordingly but individual peek windows within them keep their original widths.

---

## Window size calculation

Both layouts start from the same base: the screen's `visibleFrame` (which excludes the menu bar and Dock) minus outer gaps configured in `config.layout.outerGaps`. This gives the **tiling area**:

```
tilingArea.width  = visibleFrame.width  - outerGaps.left - outerGaps.right
tilingArea.height = visibleFrame.height - outerGaps.top  - outerGaps.bottom
```

The origin is shifted inward by the outer gaps (and y is flipped from AppKit bottom-left to AX top-left coordinates).

At the leaf level, each window's final AX frame is inset by `config.layout.innerGap` on all four sides:

```
finalPosition = slotOrigin + innerGap
finalSize     = slotSize   - innerGap * 2   (on each axis)
```

All values are `.rounded()` to whole pixels.

### Tiling size calculation

`TilingPositionService` walks the tree top-down, distributing the tiling area by fractions:

1. The root gets the full tiling area (`width × height`).
2. For each child of a container (root or split):
   - If the container's orientation is **horizontal**: `childWidth = parentWidth × child.fraction`, `childHeight = parentHeight`.
   - If the container's orientation is **vertical**: `childWidth = parentWidth`, `childHeight = parentHeight × child.fraction`.
3. This recurses into nested split containers.
4. Window leaves receive their computed size directly.

Fractions default to `1.0` and are normalized so siblings sum to 1.0. When a new window is inserted, the pair gets 50/50 fractions (0.5 each). User resizes adjust fractions with a minimum clamp of 0.05.

**Example** — 3 windows in a horizontal root on a 1920×1080 tiling area (ignoring gaps):

```
Root (horizontal, 1920×1080)
├── Window A  fraction=0.33  → 634×1080
├── Window B  fraction=0.33  → 634×1080
└── Window C  fraction=0.34  → 652×1080
```

### Scrolling size calculation

`ScrollingPositionService` splits the tiling area into three fixed zones:

1. **Center width** = `tilingArea.width × centerWidthFraction` (defaults to `config.layout.scrollCenterDefaultWidthFraction`, typically 0.9). Clamped between 0.50 and 0.95 of the tiling width.
2. **Remaining width** = `tilingArea.width - centerWidth`.
3. If both left and right sides exist: each side's **slot width** = `remaining / 2`.
4. If only one side exists: that side's **slot width** = `remaining`.

The center window gets `centerWidth × tilingArea.height`.

Side windows are wider than their slot — each side window's **rendered width equals the center width**, so they extend behind the center and only "peek" out from the edge. The side **slot width** controls how far the peek extends, while the **stacking alignment** determines which edge the windows anchor to:

- Left slot: aligned right (windows anchor to the right edge of the left zone, peeking from the left).
- Right slot: aligned left (windows anchor to the left edge of the right zone, peeking from the right).

The x-offset for a stacked side window is: `slotOrigin.x + (align == .left ? 0 : slotWidth - windowWidth)`.

**Example** — center fraction 0.9 on a 1920×1080 tiling area (ignoring gaps), one window on each side:

```
Left slot:   slot width = 96,  window width = 1728 (same as center)
Center slot: width = 1728
Right slot:  slot width = 96,  window width = 1728 (same as center)
```

The left window is positioned so its right edge aligns with the left slot's right boundary — only 96px of it is visible. Same logic mirrored for the right side.

During a center resize, side slot widths update but side **window** widths stay unchanged (`updateSideWindowWidths: false`), so the peek distance changes but the windows themselves keep their rendered size.

---

## Quick comparison

| | Tiling | Scrolling |
|---|---|---|
| Structure | Recursive split tree | 3-zone (left / center / right) |
| Focus left/right | Spatial neighbor search | Rotational scroll |
| Focus up/down | Spatial neighbor search | Not supported |
| Swap | Any direction, spatial | Left/right only |
| Insert | Drop-zone based (4 sides) | Auto-pushes center to left |
| Resize | Fraction rebalancing in tree | Center width fraction only |
| Nesting | Arbitrary depth | Flat (stacking in sides) |
