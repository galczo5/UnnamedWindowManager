# Plan: 20_center_swap — Center Drop Zone and Window Swap (Tree Model)

## Checklist

- [ ] Add `swap(_:_:)` to `ManagedSlotRegistry+SlotMutations.swift`
- [ ] Add `findSwapTarget(forKey:)` to `SnapLayout.swift`; remove disabled `findDropTarget` early-return
- [ ] Update `ResizeObserver+SwapOverlay.swift` — rewrite `updateSwapOverlay` for tree model
- [ ] Update `ResizeObserver+Reapply.swift` — perform swap on mouse-up when target found

---

## Context / Problem

The tree-model migration (plan 19) disabled all drop zones and the swap feature with
`return nil` / `return` guards. The goal here is to bring back **only the center drop zone**:
when a managed window is dragged over another managed window, they swap slots. Both windows
receive the other's allocated size and position after the swap. Non-managed windows and all
other drop zones (left/right/top/bottom) remain out of scope.

---

## Behaviour spec

- **Trigger**: cursor is over any part of a different tracked window while dragging a tracked window.
- **Feedback**: translucent blue overlay appears over the target window in real time.
- **On release**: the two windows swap leaf positions in the `ManagedSlot` tree; `reapplyAll()` assigns each window its new slot's size and position.
- **No target on release**: window snaps back to its own slot (existing behaviour).
- **Only managed windows swap**: dragging an unmanaged window has no effect.

---

## How the swap works

Each tracked window lives in a leaf `ManagedSlot`. The leaf stores the slot's `width`/`height`
(set by `recomputeSizes`). The window's identity (`pid + windowHash`) is the `.window(ManagedWindow)`
inside `slot.content`.

A swap exchanges the `ManagedWindow` values between two leaves while leaving the slots (and
therefore their sizes) in place. After `reapplyAll()`, `applyLayout` looks up each `ManagedWindow`
in `ResizeObserver.shared.elements` and moves it to its new slot's frame.

No `recomputeSizes` call is needed — slot sizes are unchanged.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Model/ManagedSlotRegistry+SlotMutations.swift` | Add `swap(_:_:)` and private `replaceWindowInLeaf` |
| `UnnamedWindowManager/Snapping/SnapLayout.swift` | Add `findSwapTarget(forKey:)`; remove disabled early-return in `findDropTarget` (or leave stub — see note) |
| `UnnamedWindowManager/Observation/ResizeObserver+SwapOverlay.swift` | Rewrite `updateSwapOverlay` for tree model |
| `UnnamedWindowManager/Observation/ResizeObserver+Reapply.swift` | Move branch: perform swap when target found |

---

## Implementation Steps

### 1. `ManagedSlotRegistry+SlotMutations.swift` — add `swap`

Replace the empty file body with two methods: the public `swap` entry point and the
private recursive `replaceWindowInLeaf` helper.

```swift
extension ManagedSlotRegistry {

    /// Swaps the two tracked windows in the tree.
    /// Each window moves to the other's leaf slot; slot sizes are unchanged.
    func swap(_ keyA: ManagedWindow, _ keyB: ManagedWindow) {
        queue.sync(flags: .barrier) {
            guard findLeafSlot(keyA, in: root) != nil,
                  findLeafSlot(keyB, in: root) != nil else { return }
            replaceWindowInLeaf(&root, target: keyA, with: keyB)
            replaceWindowInLeaf(&root, target: keyB, with: keyA)
        }
    }

    @discardableResult
    private func replaceWindowInLeaf(
        _ slot: inout ManagedSlot,
        target: ManagedWindow,
        with replacement: ManagedWindow
    ) -> Bool {
        if case .window(let w) = slot.content, w == target {
            slot.content = .window(replacement)
            return true
        }
        if case .slots(var children) = slot.content {
            for i in children.indices {
                if replaceWindowInLeaf(&children[i], target: target, with: replacement) {
                    slot.content = .slots(children)
                    return true
                }
            }
        }
        return false
    }
}
```

`findLeafSlot` is a private method on `ManagedSlotRegistry` (already exists) — the guard
confirms both keys are currently tracked before mutating.

### 2. `SnapLayout.swift` — add `findSwapTarget(forKey:)`

Add the new method to the `WindowSnapper` extension. It reads actual window positions from
AX (via `ResizeObserver.shared.elements`) and hit-tests the cursor against each managed
window's current frame.

```swift
/// Returns the tracked window under the cursor, or nil if none (or only the dragged window).
static func findSwapTarget(forKey draggedKey: ManagedWindow) -> ManagedWindow? {
    let cursor = NSEvent.mouseLocation           // AppKit coords (bottom-left origin)
    let screenHeight = NSScreen.screens[0].frame.height
    let leaves = ManagedSlotRegistry.shared.allLeaves()
    let elements = ResizeObserver.shared.elements

    for leaf in leaves {
        guard case .window(let w) = leaf.content, w != draggedKey else { continue }
        guard let axElement = elements[w],
              let axOrigin = readOrigin(of: axElement),
              let axSize   = readSize(of: axElement) else { continue }

        // AX coords: top-left origin, y increases downward.
        // AppKit coords: bottom-left origin, y increases upward.
        let appKitY = screenHeight - axOrigin.y - axSize.height
        let frame = CGRect(x: axOrigin.x, y: appKitY, width: axSize.width, height: axSize.height)

        if frame.contains(cursor) { return w }
    }
    return nil
}
```

The existing disabled `findDropTarget` stub can remain as-is (still returns nil) —
it is not called by the new code path.

### 3. `ResizeObserver+SwapOverlay.swift` — rewrite `updateSwapOverlay`

Remove the `hideSwapOverlay(); return` early-exit and replace the body with the
tree-model implementation. The overlay frame is derived directly from the target
window's live AX position and size.

```swift
func updateSwapOverlay(for draggedKey: ManagedWindow, draggedWindow: AXUIElement) {
    guard let targetWindow = WindowSnapper.findSwapTarget(forKey: draggedKey),
          let targetElement = elements[targetWindow],
          let axOrigin = WindowSnapper.readOrigin(of: targetElement),
          let axSize   = WindowSnapper.readSize(of: targetElement) else {
        hideSwapOverlay()
        return
    }

    let screenHeight = NSScreen.screens[0].frame.height
    let appKitY = screenHeight - axOrigin.y - axSize.height
    let overlayFrame = CGRect(x: axOrigin.x, y: appKitY, width: axSize.width, height: axSize.height)
    let draggedWindowNumber = WindowSnapper.windowID(of: draggedWindow).map(Int.init)
    showSwapOverlay(frame: overlayFrame, belowWindow: draggedWindowNumber)
}
```

`showSwapOverlay` and `hideSwapOverlay` are unchanged.

### 4. `ResizeObserver+Reapply.swift` — perform swap on mouse-up

Replace the move branch (currently `// Move: restore position. Drop zones disabled`)
with swap detection:

```swift
} else {
    // Move: check for swap target, otherwise restore position.
    if let swapTarget = WindowSnapper.findSwapTarget(forKey: key) {
        let allWindows = self.allTrackedWindows()
        self.reapplying.formUnion(allWindows)
        ManagedSlotRegistry.shared.swap(key, swapTarget)
        WindowSnapper.reapplyAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.reapplying.subtract(allWindows)
        }
    } else {
        self.reapplying.insert(key)
        WindowSnapper.reapply(window: storedElement, key: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.reapplying.remove(key)
        }
    }
}
```

`allTrackedWindows()` is already a private helper in this file — it collects all window
keys from `allLeaves()`.

---

## Key Technical Notes

- `replaceWindowInLeaf` is called twice in `swap`: once for each key. The first call
  writes keyB into keyA's leaf; the second call writes keyA into keyB's leaf. Order
  matters only if the two keys could somehow share a leaf — they cannot, since each
  leaf holds exactly one window.
- `ResizeObserver.shared.elements` is accessed from `findSwapTarget` on the main thread
  (all AX callback and polling code runs on main). No locking needed.
- The swap reads the window's **live AX position** (not the slot's computed position)
  for hit-testing and overlay placement. This is intentional: during a drag the window
  is at its dragged position, not its slot position.
- `reapplyAll()` inside the swap branch calls `ResizeObserver.shared.reapplying.formUnion`
  internally as well — the outer `formUnion` in the Reapply code runs first, which is
  fine (union is idempotent).
- `findSwapTarget` uses `NSScreen.screens[0].frame.height` (the primary screen's full
  height) for the AX→AppKit Y conversion — the same convention used throughout the
  existing codebase.
- The overlay is ordered below the dragged window (`order(.below, relativeTo:)`) so it
  does not obscure the window being moved.
- After a swap, both windows are in the `reapplying` set, so the AX moved/resized
  notifications fired by `reapplyAll()` are ignored.

---

## Verification

1. Snap Finder → fills screen. Snap Safari → splits vertically (Finder top, Safari bottom).
2. Drag Finder over Safari → blue overlay appears over Safari.
3. Release → windows swap: Safari is now top, Finder is bottom. Both sizes unchanged.
4. Drag Safari back over Finder → overlay appears; release → windows return to original positions.
5. Drag Finder to empty screen space (not over Safari) → no overlay; Finder snaps back.
6. Snap a third window Terminal → three-window tree. Drag top window over bottom window → only those two swap; middle window is unaffected.
7. Rapidly drag between windows → overlay tracks correctly; no stale overlays left after release.
