# Plan: 19_audit_services — Audit Services/ for duplication, dead code, and quality

## Checklist

- [x] Extract `screenTilingArea` helper to eliminate outer-gaps boilerplate
- [x] Extract `pushCenterToSide` helper in ScrollingTileService
- [x] Unify `allWindowSlots` and `windowHashes` in ScrollingTileService
- [x] Extract `removeRoot` helper on SharedRootStore
- [ ] ~~Remove dead `WindowOpacityService.restore(hash:)`~~ (actually used — skipped)
- [x] Remove dead `SharedRootStore.snapshotRoot(id:)`
- [x] Fix duplicate file-purpose comment in ScrollingPositionService
- [x] Clean up one-liner filter in `ScrollingTileService.removeAllScrollingRoots`

---

## Context / Problem

The `Services/` directory (17 files, ~2000 lines) has accumulated several patterns of duplication and a few pieces of dead code. This audit targets concrete, low-risk improvements without restructuring the architecture.

---

## Findings by file

### ScrollingTileService.swift (411 lines)

1. **Duplication — outer-gaps boilerplate** (lines 65-67, 115-117, 148-150, 187-189, 232-234, 291-292, 349-351): The three-line pattern `let og = Config.outerGaps; let w = screen.visibleFrame.width - og.left! - og.right!; let h = screen.visibleFrame.height - og.top! - og.bottom!` appears 7 times in this file alone, and 19 times across the codebase. Extract to a helper.

2. **Duplication — "push old center into side stacking slot"**: The pattern of moving `root.center` into `root.left` (or `root.right`) via a `switch` on nil/stacking appears in `addWindow` (lines 98-111), `scrollRight` (lines 134-145), and `scrollLeft` (lines 172-183). Extract to a private helper.

3. **Duplication — `allWindowSlots` vs `windowHashes`**: These two private methods (lines 382-410) perform identical tree traversals — one collecting `WindowSlot`, the other `UInt`. `windowHashes` can be derived from `allWindowSlots` via `.map(\.windowHash)`.

4. **Quality — complex one-liner filter** (line 212): `store.roots.keys.filter { if case .scrolling = store.roots[$0]! { return true }; return false }` is hard to read.

### TileService.swift (322 lines)

5. **Duplication — outer-gaps boilerplate**: Same 3-line pattern appears 6 times (lines 126-129, 182-185, 197-199, 225-228, 239-241, 282-284).

6. **Duplication — `removeRoot` idiom**: The pair `store.roots.removeValue(forKey: id); store.windowCounts.removeValue(forKey: id)` appears 7 times across TileService (lines 103-104, 139-140, 152-153, 165-166, 179-180) and ScrollingTileService (lines 204-205, 218, 248-249). Extract to a method on `SharedRootStore`.

7. **Quality — complex one-liner filter** (line 147): Same pattern as ScrollingTileService line 212.

### WindowOpacityService.swift (97 lines)

8. **Dead code — `restore(hash:)`** (line 47): Never called anywhere in the codebase. It just delegates to `restoreAll()`.

### SharedRootStore.swift (20 lines)

9. **Dead code — `snapshotRoot(id:)`** (line 17): Never called anywhere in the codebase.

### ScrollingPositionService.swift (63 lines)

10. **Quality — duplicate file-purpose comment** (lines 3-4): The comment `// Computes pixel dimensions for all zones of a ScrollingRootSlot.` is repeated twice.

### KeybindingService.swift (280 lines)

In the 200-300 range. Shortcut parsing/display (`parse`, `normalize`, `displayString`) is logically distinct from event-tap management, but they're cohesive enough that splitting would create two tightly-coupled halves. **No action recommended.**

### Other files

No issues found in: SlotTreeQueryService, SlotTreeMutationService, SlotTreeInsertService, ResizeService, PositionService, ScrollingResizeService, DirectionalNeighborService, FocusDirectionService, SwapDirectionService, NotificationService, CommandService.

---

## Files to create / modify

| File | Action |
|------|--------|
| `System/ScreenHelper.swift` | **New file** — `screenTilingArea(_:) -> CGSize` helper |
| `Services/SharedRootStore.swift` | Modify — add `removeRoot(id:)` helper |
| `Services/ScrollingTileService.swift` | Modify — use helpers, remove `windowHashes`, extract `pushCenterToSide`, clean up filter |
| `Services/TileService.swift` | Modify — use helpers, clean up filter |
| `Services/WindowOpacityService.swift` | Modify — remove dead `restore(hash:)` |
| `Services/ScrollingPositionService.swift` | Modify — remove duplicate comment |

---

## Implementation Steps

### 1. Extract `screenTilingArea` helper

Create a free function (or static on a small helper) that encapsulates the outer-gaps subtraction:

```swift
// Returns the usable tiling area after subtracting outer gaps from the screen's visible frame.
func screenTilingArea(_ screen: NSScreen) -> CGSize {
    let og = Config.outerGaps
    return CGSize(
        width:  screen.visibleFrame.width  - og.left! - og.right!,
        height: screen.visibleFrame.height - og.top!  - og.bottom!
    )
}
```

Then replace every 3-line `let og = …; let w = …; let h = …` block with `let area = screenTilingArea(screen)` and use `area.width` / `area.height`.

### 2. Extract `pushCenterToSide` in ScrollingTileService

Private helper that moves `root.center` into a side stacking slot:

```swift
private func pushCenterToSide(
    _ center: WindowSlot, into side: inout Slot?,
    parentId: UUID, align: StackingSlot.Alignment
) {
    switch side {
    case nil:
        side = .stacking(StackingSlot(id: UUID(), parentId: parentId,
                                       size: .zero, children: [center], align: align))
    case .stacking(var s):
        s.children.append(center)
        side = .stacking(s)
    default:
        break
    }
}
```

Replace the three duplicated switch blocks in `addWindow`, `scrollRight`, and `scrollLeft`.

### 3. Unify `allWindowSlots` and `windowHashes`

Remove `windowHashes(in:)`. Replace its call sites with `allWindowSlots(in: root).map(\.windowHash)`.

### 4. Add `removeRoot(id:)` on SharedRootStore

```swift
func removeRoot(id: UUID) {
    roots.removeValue(forKey: id)
    windowCounts.removeValue(forKey: id)
}
```

Replace all 7 occurrences of the two-line idiom.

### 5. Remove dead code

- Delete `WindowOpacityService.restore(hash:)`.
- Delete `SharedRootStore.snapshotRoot(id:)`.

### 6. Fix duplicate comment and one-liner filters

- Remove the duplicated comment line in `ScrollingPositionService.swift`.
- Rewrite the filter one-liners in `TileService.removeAllTilingRoots` and `ScrollingTileService.removeAllScrollingRoots` for readability.

---

## Key Technical Notes

- `screenTilingArea` must be usable from inside `store.queue.sync` blocks — it only reads `Config` and `NSScreen`, both safe from any thread.
- `pushCenterToSide` takes `side` as `inout Slot?` so it works for both `root.left` and `root.right`.
- The `removeRoot(id:)` helper must only be called inside a barrier block on `store.queue` — callers already satisfy this.
- `allWindowSlots(in:).map(\.windowHash)` is trivially more allocation than the dedicated `windowHashes` method, but the lists are always tiny (< 10 elements).

---

## Verification

1. Build with `./build.sh` after each file change
2. Tile 3 windows → untile → confirm no regression
3. Scroll-organize 3 windows → scroll left/right → unscroll → confirm no regression
4. Resize a tiled window → confirm resize fractions still apply
5. Focus left/right/up/down → confirm directional focus works
6. Swap left/right → confirm swap works in both tiling and scrolling modes
