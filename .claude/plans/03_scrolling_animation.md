# Plan: 03_scrolling_animation — Dedicated ScrollingAnimationService for focus left/right

## Checklist

- [ ] Create `ScrollingAnimationService.swift` with `animateScroll` and `animate` methods
- [ ] Add `computePositions` helper inside `ScrollingAnimationService`
- [ ] Modify `ScrollingLayoutService` to call `ScrollingAnimationService.animate` instead of `AnimationService.animate`
- [ ] Modify `ScrollingFocusService.scrollLeft` / `scrollRight` to call `animateScroll`
- [ ] Update `CODE.md`

---

## Context / Problem

`AnimationService` works well for tiling roots but produces poor results during scrolling focus left/right for two reasons:

**1. Jumpy rapid scrolling.** `AnimationService.animate` reads the current AX position of each window as the animation start point. When the user scrolls quickly the previous animation is cancelled mid-flight, leaving the window at an interpolated on-screen position. The next animation then starts from that mid-position, producing a jump or reversal artefact.

**2. No directional awareness.** When scrolling left, the incoming window (was on the left stack) and the outgoing window (was the center) should animate in coordinated left→right motion. The current generic service animates each window independently from wherever it happens to be on-screen, with no knowledge of scroll direction or window order within the stack.

**Goal.** A new `ScrollingAnimationService` that:
- Uses the *logical before-state positions* as animation start points (not current AX positions), so rapid scrolling always produces coherent motion.
- Identifies which windows are *transitioning* (center ↔ side) and animates only those; all other side-stack windows are applied immediately.
- Has its own `CVDisplayLink` entirely separate from `AnimationService`, so tiling and scrolling animations never interfere.

---

## Scroll direction / window order note

In `ScrollingRootSlot`:
- `left.children.last` is the window **closest to center** on the left — the next one to become center when scrolling left.
- `right.children.last` is the window **closest to center** on the right — the next one to become center when scrolling right.

After `scrollLeft()`: old `left.children.last` → new center; old center → appended to right stack.
After `scrollRight()`: old `right.children.last` → new center; old center → appended to left stack.

The transitioning windows are identified by comparing the center slot hashes between `before` and `after`:
- **Outgoing** = was in `before.center`, is now on a side.
- **Incoming** = is now in `after.center`, was on a side in `before`.

---

## Files to create / modify

| File | Action |
|------|--------|
| `Services/Scrolling/ScrollingAnimationService.swift` | **New file** — direction-aware scroll animator |
| `Services/Scrolling/ScrollingLayoutService.swift` | Modify — use `ScrollingAnimationService.animate` instead of `AnimationService.animate` |
| `Services/Scrolling/ScrollingFocusService.swift` | Modify — replace two-step `applyLayout` calls with `animateScroll` |
| `UnnamedWindowManager/CODE.md` | Modify — add `ScrollingAnimationService` entry |

---

## Implementation Steps

### 1. Create `ScrollingAnimationService.swift`

New file in `Services/Scrolling/`. Mirrors the CVDisplayLink infrastructure of `AnimationService` but adds a `animateScroll` entry point that uses before-state positions as starts.

```swift
/// Direction-aware window animator for scrolling roots.
/// Uses logical before-layout positions as start points to prevent jump artefacts on rapid scrolling.
final class ScrollingAnimationService {
    static let shared = ScrollingAnimationService()
    private init() {}

    enum ScrollDirection { case left, right }

    private struct Animation {
        let ax: AXUIElement
        let key: WindowSlot
        let startPos: CGPoint
        let startSize: CGSize
        let endPos: CGPoint
        let endSize: CGSize
        let startTime: CFAbsoluteTime
        let duration: CFTimeInterval
        let sizeChanged: Bool
    }

    private var animations: [UInt: Animation] = [:]
    private var displayLink: CVDisplayLink?

    var isAnimating: Bool { !animations.isEmpty }
```

#### `animateScroll`

The main entry point for `scrollLeft` / `scrollRight`. Takes the full before and after root snapshots.

```swift
func animateScroll(direction: ScrollDirection,
                   before: ScrollingRootSlot,
                   after: ScrollingRootSlot,
                   origin: CGPoint,
                   elements: [WindowSlot: AXUIElement]) {
    let duration = Config.animationDuration
    let beforePos = computePositions(root: before, origin: origin)
    let afterPos  = computePositions(root: after,  origin: origin)

    let transitioning = transitioningHashes(before: before, after: after)
    let zonesChanged  = (before.left != nil) != (after.left != nil)
                     || (before.right != nil) != (after.right != nil)

    // Build a hash → (key, ax) lookup from elements
    let keysByHash = Dictionary(uniqueKeysWithValues: elements.map { ($0.key.windowHash, $0) })

    for (hash, end) in afterPos {
        guard let (key, ax) = keysByHash[hash] else { continue }
        let start = beforePos[hash] ?? end

        let posDelta  = abs(start.pos.x - end.pos.x)  + abs(start.pos.y - end.pos.y)
        let sizeDelta = abs(start.size.width - end.size.width) + abs(start.size.height - end.size.height)
        guard posDelta >= 1 || sizeDelta >= 1 else { continue }

        if duration > 0 && (transitioning.contains(hash) || zonesChanged) {
            cancel(hash: hash)
            ResizeObserver.shared.reapplying.insert(key)
            animations[hash] = Animation(
                ax: ax, key: key,
                startPos: start.pos, startSize: start.size,
                endPos: end.pos,   endSize: end.size,
                startTime: CFAbsoluteTimeGetCurrent(),
                duration: duration,
                sizeChanged: sizeDelta >= 1
            )
        } else {
            applyImmediate(ax: ax, pos: end.pos, size: end.size)
        }
    }
    startDisplayLinkIfNeeded()
}
```

#### `animate`

Used by `ScrollingLayoutService` for non-scroll repositioning (resize, `scrollToCenter`). Reads current AX position as start — same behaviour as `AnimationService.animate`.

```swift
func animate(key: WindowSlot, ax: AXUIElement, to pos: CGPoint, size: CGSize,
             positionOnly: Bool = false) {
    let duration = Config.animationDuration
    cancel(hash: key.windowHash)

    guard duration > 0,
          let curPos  = readOrigin(of: ax),
          let curSize = readSize(of: ax) else {
        applyImmediate(ax: ax, pos: pos, size: size, positionOnly: positionOnly)
        return
    }

    let posDelta  = abs(curPos.x - pos.x) + abs(curPos.y - pos.y)
    let sizeDelta = abs(curSize.width - size.width) + abs(curSize.height - size.height)
    if posDelta < 1 && (positionOnly || sizeDelta < 1) { return }

    ResizeObserver.shared.reapplying.insert(key)
    animations[key.windowHash] = Animation(
        ax: ax, key: key,
        startPos: curPos, startSize: curSize,
        endPos: pos, endSize: size,
        startTime: CFAbsoluteTimeGetCurrent(),
        duration: duration,
        sizeChanged: !positionOnly && sizeDelta >= 1
    )
    startDisplayLinkIfNeeded()
}
```

#### `computePositions`

Mirrors the position math from `ScrollingLayoutService.applySlot` but returns a dictionary instead of applying.

```swift
private func computePositions(root: ScrollingRootSlot,
                               origin: CGPoint) -> [UInt: (pos: CGPoint, size: CGSize)] {
    var result: [UInt: (pos: CGPoint, size: CGSize)] = [:]
    let leftWidth   = root.left?.size.width ?? 0
    let centerWidth = root.center.size.width

    if let left = root.left {
        collectPositions(left,  origin: CGPoint(x: origin.x, y: origin.y), into: &result)
    }
    collectPositions(root.center,
                     origin: CGPoint(x: origin.x + leftWidth, y: origin.y),
                     into: &result)
    if let right = root.right {
        collectPositions(right,
                         origin: CGPoint(x: origin.x + leftWidth + centerWidth, y: origin.y),
                         into: &result)
    }
    return result
}

private func collectPositions(_ slot: Slot, origin: CGPoint,
                               into result: inout [UInt: (pos: CGPoint, size: CGSize)]) {
    switch slot {
    case .window(let w):
        let g = w.gaps ? Config.innerGap : 0
        let pos  = CGPoint(x: (origin.x + g).rounded(), y: (origin.y + g).rounded())
        let size = CGSize(width: (w.size.width - g * 2).rounded(),
                          height: (w.size.height - g * 2).rounded())
        result[w.windowHash] = (pos, size)
    case .stacking(let s):
        for w in s.children {
            let g = w.gaps ? Config.innerGap : 0
            let xOffset: CGFloat = s.align == .left ? 0 : s.size.width - w.size.width
            let pos  = CGPoint(x: (origin.x + xOffset + g).rounded(), y: (origin.y + g).rounded())
            let size = CGSize(width: (w.size.width - g * 2).rounded(),
                              height: (w.size.height - g * 2).rounded())
            result[w.windowHash] = (pos, size)
        }
    default: break
    }
}
```

#### `transitioningHashes`

```swift
private func transitioningHashes(before: ScrollingRootSlot,
                                  after: ScrollingRootSlot) -> Set<UInt> {
    let beforeCenter = slotHashes(before.center)
    let afterCenter  = slotHashes(after.center)
    return beforeCenter.symmetricDifference(afterCenter)
}

private func slotHashes(_ slot: Slot) -> Set<UInt> {
    switch slot {
    case .window(let w):    return [w.windowHash]
    case .stacking(let s):  return Set(s.children.map(\.windowHash))
    default:                return []
    }
}
```

#### CVDisplayLink + tick

Copy the `startDisplayLinkIfNeeded`, `stopDisplayLinkIfIdle`, `tickAll`, `cancel`, `cancelAll`, `easeOutQuart`, `applyImmediate`, `readOrigin`, `readSize` methods verbatim from `AnimationService`. They are identical in behaviour; the duplication is intentional so the two services remain fully independent.

---

### 2. Modify `ScrollingLayoutService`

Replace both `AnimationService.shared.animate` call sites with `ScrollingAnimationService.shared.animate`:

```swift
// In applySlot, case .window:
ScrollingAnimationService.shared.animate(key: w, ax: ax, to: pos, size: size, positionOnly: positionOnly)

// In applySlot, case .stacking:
ScrollingAnimationService.shared.animate(key: w, ax: ax, to: pos, size: size, positionOnly: positionOnly)
```

No other changes to `ScrollingLayoutService`.

---

### 3. Modify `ScrollingFocusService`

Replace the two-step `applyLayout` pattern in `scrollLeft` and `scrollRight` with a single `animateScroll` call. Also guard on `before` being non-nil (in practice it always is if `newCenter` is non-nil, but the guard makes this explicit).

```swift
static func scrollLeft() {
    guard let screen = NSScreen.main else { return }
    guard let before = ScrollingRootStore.shared.snapshotVisibleScrollingRoot() else { return }
    guard let newCenter = ScrollingRootStore.shared.scrollLeft(screen: screen) else { return }
    guard let after = ScrollingRootStore.shared.snapshotVisibleScrollingRoot() else { return }
    let origin   = layoutOrigin(screen: screen)
    let elements = ResizeObserver.shared.elements

    ScrollingAnimationService.shared.animateScroll(
        direction: .left, before: before, after: after,
        origin: origin, elements: elements
    )
    activateAfterLayout(newCenter)
}
```

Apply the same pattern to `scrollRight` (direction: `.right`).

`scrollToCenter` is unchanged — it still calls `ScrollingLayoutService.applyLayout` which now routes through `ScrollingAnimationService.animate`.

---

### 4. Update CODE.md

Add a row for `ScrollingAnimationService.swift` in the `Services/Scrolling/` table:

```
| `ScrollingAnimationService.swift` | Direction-aware animator for scroll left/right; uses before-state positions to prevent jump artefacts |
```

---

## Key Technical Notes

- `ScrollingAnimationService` has its **own `CVDisplayLink`**, completely independent of `AnimationService`. Both can be running simultaneously if the user has both a tiling and a scrolling root active.
- `computePositions` replicates the gap/alignment math from `ScrollingLayoutService.applySlot`. If gap logic changes in `applySlot`, it must be updated here too.
- `animateScroll` iterates `afterPos` (not `beforePos`) so that windows newly added to a zone (the outgoing center joining the right stack) are always included.
- A window present in `beforePos` but absent in `afterPos` (removed from layout mid-scroll) is simply not animated — no crash, no stale entry.
- For `zonesChanged = true` (a side zone appears or disappears), ALL windows are animated because every zone width changes. The before-state positions ensure these start from the correct logical width, not the already-resized AX frame.
- `scrollToCenter` still uses the two-step `applyLayout` path through `ScrollingLayoutService` → `ScrollingAnimationService.animate`. The before-position fix does NOT apply there; it will still read current AX positions. This is acceptable — `scrollToCenter` is rare and involves multiple simultaneous transitions that are harder to choreograph directionally.
- `ResizeObserver.shared.reapplying.insert(key)` must be called before each animation starts (as in `AnimationService`) to suppress resize-reapply callbacks during animation.
- The `cancel` + `stopDisplayLinkIfIdle` pattern must be preserved so the CVDisplayLink stops when all animations finish.

---

## Verification

1. Snap three windows into a scrolling root → press focus-left → center window slides left, incoming window slides in from left, no jump.
2. Rapidly press focus-left several times → motion stays coherent; no direction reversals or position jumps.
3. Scroll until the left stack empties (zonesChanged) → all windows animate to their new widths simultaneously.
4. Resize center zone (drag or keybind) → side windows reposition smoothly (via `ScrollingAnimationService.animate` path).
5. Scroll to a window buried deep in the left stack (scrollToCenter) → windows animate, no crash.
6. Tile windows on a second space and operate them → tiling animations unaffected (still use `AnimationService`).
7. Set `animationDuration: 0` in config → all scroll operations apply immediately, no CVDisplayLink created.
