# Plan: 03_archived — [ARCHIVED] Direction-Aware Scrolling Animation Service

> **Archived** — This entry consolidates plans [03 `03_scrolling_animation`].
> These plans have been completed and their details removed. Only key context is preserved.

---

## What This Covered

Introduced `ScrollingAnimationService`, a dedicated CVDisplayLink-based animator for scrolling roots that uses logical before-state positions as animation start points, preventing jump artefacts during rapid scroll left/right. `ScrollingFocusService` was updated to call `animateScroll` directly instead of the two-step `applyLayout` pattern, and `ScrollingLayoutService` was updated to route through `ScrollingAnimationService.animate` instead of `AnimationService.animate`, keeping tiling and scrolling animations fully independent.

---

## Plans Consolidated

| Original # | Name | Summary |
|---|---|---|
| 03 | `03_scrolling_animation` | Created a direction-aware scroll animator that uses before-state positions to prevent jumps and reversal artefacts on rapid left/right scrolling |

---

## Important Files

`UnnamedWindowManager/Services/Scrolling/ScrollingAnimationService.swift`
`UnnamedWindowManager/Services/Scrolling/ScrollingLayoutService.swift`
`UnnamedWindowManager/Services/Scrolling/ScrollingFocusService.swift`

---
