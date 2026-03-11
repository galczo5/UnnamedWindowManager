# Plan: 15_scrolling_root_activation — Scroll menu action and scrolling root layout

## Checklist

- [ ] Make `ScrollingRootSlot.left` and `.right` optional (`Slot?`)
- [ ] Create `ScrollingPositionService.swift` — computes pixel dimensions for each zone
- [ ] Create `ScrollingTileService.swift` — creates root, adds windows, snapshots visible root
- [ ] Create `ScrollingLayoutService.swift` — applies AX positions/sizes for scrolling root
- [ ] Create `ScrollingRootHandler.swift` — gets focused window, delegates to ScrollingTileService
- [ ] Update `LayoutService.swift` — call scrolling layout after tiling layout
- [ ] Update `UnnamedWindowManagerApp.swift` — add "Scroll" button (hidden when `isTiled`)
- [ ] Update `WindowLister.swift` — log left/center/right slot contents

---

## Context / Problem

`ScrollingRootSlot` and `RootSlot` exist in the model (plan 13) but are never created or laid out. This plan wires them up end-to-end:

1. A new "Scroll" menu button creates a `ScrollingRootSlot` and places the active window in the center zone.
2. Pressing "Scroll" again (with a different window focused) moves the current center window into a `StackingSlot` on the left and promotes the new window to center.
3. `LayoutService` is updated to also walk and apply scrolling roots after tiling roots.

---

## Behaviour spec

**Button guard:** "Scroll" is only shown when `!menuState.isTiled` (no visible tiling root with windows). If a tiling root is active, the button is hidden.

**First Scroll press (no scrolling root exists):**
- Creates a `ScrollingRootSlot` with the focused window as `center`.
- `left` and `right` are `nil`.

**Subsequent Scroll presses (scrolling root visible):**
- If `left == nil`: wraps the current center `WindowSlot` in a new `StackingSlot` and assigns it to `left`. New window becomes `center`.
- If `left` is already a `StackingSlot`: appends the current center window to the existing stacking slot's children. New window becomes `center`.

**Layout — zone widths (outer gaps already subtracted):**

| State | left | center | right |
|-------|------|--------|-------|
| only center | — | x=0, w=80% | — |
| left + center | x=0, w=20% | x=20%, w=80% | — |
| left + center + right | x=0, w=10% | x=10%, w=80% | x=90%, w=10% |

All zones always get `height = 100%` of the (gap-adjusted) screen height.

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Model/ScrollingRootSlot.swift` | Modify — make `left` and `right` `Slot?` |
| `UnnamedWindowManager/Services/ScrollingPositionService.swift` | **New file** — computes zone widths and assigns sizes |
| `UnnamedWindowManager/Services/ScrollingTileService.swift` | **New file** — creates/mutates scrolling roots, snapshots visible root |
| `UnnamedWindowManager/System/ScrollingLayoutService.swift` | **New file** — walks scrolling root and writes AX positions/sizes |
| `UnnamedWindowManager/System/ScrollingRootHandler.swift` | **New file** — gets focused window, calls ScrollingTileService, triggers reapply |
| `UnnamedWindowManager/System/LayoutService.swift` | Modify — also call `ScrollingLayoutService` in `applyLayout(screen:)` |
| `UnnamedWindowManager/UnnamedWindowManagerApp.swift` | Modify — add "Scroll" button when `!menuState.isTiled` |
| `UnnamedWindowManager/System/WindowLister.swift` | Modify — log left/center/right slot contents for scrolling root |

---

## Implementation Steps

### 1. Update `ScrollingRootSlot`

Make `left` and `right` optional so "empty" is represented as `nil`. `center` is always occupied after root creation.

```swift
struct ScrollingRootSlot {
    var id: UUID
    var width: CGFloat
    var height: CGFloat
    var left: Slot?
    var center: Slot
    var right: Slot?
}
```

### 2. Create `ScrollingPositionService`

Computes zone widths and assigns pixel sizes to every slot and its children. The `left`/`right` widths split the remaining 20% equally when both are occupied, or one side takes all 20% when only one is present.

```swift
// Computes pixel dimensions for all zones of a ScrollingRootSlot.
struct ScrollingPositionService {
    private let centerFraction: CGFloat = 0.8

    func recomputeSizes(_ root: inout ScrollingRootSlot, width: CGFloat, height: CGFloat) {
        root.width  = width
        root.height = height
        let centerWidth = (width * centerFraction).rounded()
        let remaining   = width - centerWidth
        let bothSides   = root.left != nil && root.right != nil
        let sideWidth   = bothSides ? (remaining / 2).rounded() : remaining

        if root.left  != nil { setSizes(&root.left!,  width: sideWidth,   height: height) }
        setSizes(&root.center,                          width: centerWidth, height: height)
        if root.right != nil { setSizes(&root.right!, width: sideWidth,   height: height) }
    }

    private func setSizes(_ slot: inout Slot, width: CGFloat, height: CGFloat) {
        switch slot {
        case .window(var w):
            w.width = width; w.height = height
            slot = .window(w)
        case .stacking(var s):
            s.width = width; s.height = height
            for i in s.children.indices {
                s.children[i].width = width; s.children[i].height = height
            }
            slot = .stacking(s)
        default:
            break
        }
    }
}
```

### 3. Create `ScrollingTileService`

Manages the lifecycle of scrolling roots: creation, adding windows, and providing a snapshot for the layout pass.

```swift
// Manages ScrollingRootSlot creation and mutation in SharedRootStore.
final class ScrollingTileService {
    static let shared = ScrollingTileService()
    private init() {}

    private let store    = SharedRootStore.shared
    private let position = ScrollingPositionService()

    func snapshotVisibleScrollingRoot() -> ScrollingRootSlot? {
        store.queue.sync {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(let root) = store.roots[id] else { return nil }
            return root
        }
    }

    func isTracked(_ key: WindowSlot) -> Bool {
        store.queue.sync {
            store.roots.values.contains { rootSlot in
                guard case .scrolling(let root) = rootSlot else { return false }
                return containsWindow(key, in: root)
            }
        }
    }

    func createScrollingRoot(key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            let id  = UUID()
            let og  = Config.outerGaps
            let w   = screen.visibleFrame.width  - og.left! - og.right!
            let h   = screen.visibleFrame.height - og.top!  - og.bottom!
            let win = WindowSlot(pid: key.pid, windowHash: key.windowHash,
                                 id: UUID(), parentId: id, order: 1,
                                 width: 0, height: 0, gaps: true,
                                 preTileOrigin: key.preTileOrigin, preTileSize: key.preTileSize)
            var root = ScrollingRootSlot(id: id, width: w, height: h,
                                         left: nil, center: .window(win), right: nil)
            position.recomputeSizes(&root, width: w, height: h)
            store.roots[id] = .scrolling(root)
            store.windowCounts[id] = 1
        }
    }

    func addWindow(_ key: WindowSlot, screen: NSScreen) {
        store.queue.sync(flags: .barrier) {
            guard let id = visibleScrollingRootID(),
                  case .scrolling(var root) = store.roots[id] else { return }
            guard !containsWindow(key, in: root) else { return }

            store.windowCounts[id, default: 0] += 1
            let order = store.windowCounts[id]!
            let newWin = WindowSlot(pid: key.pid, windowHash: key.windowHash,
                                    id: UUID(), parentId: id, order: order,
                                    width: 0, height: 0, gaps: true,
                                    preTileOrigin: key.preTileOrigin, preTileSize: key.preTileSize)

            // Move old center to left slot (into existing StackingSlot or a new one).
            if case .window(let oldCenter) = root.center {
                switch root.left {
                case nil:
                    let stacking = StackingSlot(id: UUID(), parentId: id,
                                                width: 0, height: 0,
                                                children: [oldCenter],
                                                align: .left, order: .lifo)
                    root.left = .stacking(stacking)
                case .stacking(var s):
                    s.children.append(oldCenter)
                    root.left = .stacking(s)
                default:
                    break
                }
            }

            root.center = .window(newWin)
            let og = Config.outerGaps
            let w  = screen.visibleFrame.width  - og.left! - og.right!
            let h  = screen.visibleFrame.height - og.top!  - og.bottom!
            position.recomputeSizes(&root, width: w, height: h)
            store.roots[id] = .scrolling(root)
        }
    }

    // MARK: - Private

    private func visibleScrollingRootID() -> UUID? {
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let cgList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        var visibleHashes = Set<UInt>()
        for info in cgList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid  = info[kCGWindowOwnerPID as String] as? Int,
                  let wid  = info[kCGWindowNumber as String] as? CGWindowID,
                  pid_t(pid) != ownPID else { continue }
            visibleHashes.insert(UInt(wid))
        }

        for (id, rootSlot) in store.roots {
            guard case .scrolling(let root) = rootSlot else { continue }
            if windowHashes(in: root).contains(where: { visibleHashes.contains($0) }) { return id }
        }
        return nil
    }

    private func containsWindow(_ key: WindowSlot, in root: ScrollingRootSlot) -> Bool {
        windowHashes(in: root).contains(key.windowHash)
    }

    /// Collects every windowHash tracked in this scrolling root.
    private func windowHashes(in root: ScrollingRootSlot) -> [UInt] {
        var hashes: [UInt] = []
        func collect(_ slot: Slot) {
            switch slot {
            case .window(let w): hashes.append(w.windowHash)
            case .stacking(let s): s.children.forEach { hashes.append($0.windowHash) }
            default: break
            }
        }
        if let left = root.left  { collect(left) }
        collect(root.center)
        if let right = root.right { collect(right) }
        return hashes
    }
}
```

### 4. Create `ScrollingLayoutService`

Walks a `ScrollingRootSlot` and writes AX positions and sizes. Mirror of `LayoutService`'s private slot walker, but zone origins are computed from zone widths.

```swift
// Applies window positions and sizes for a ScrollingRootSlot via the Accessibility API.
final class ScrollingLayoutService {
    static let shared = ScrollingLayoutService()
    private init() {}

    func applyLayout(root: ScrollingRootSlot, origin: CGPoint,
                     elements: [WindowSlot: AXUIElement]) {
        let centerWidth = (root.width * 0.8).rounded()
        let remaining   = root.width - centerWidth
        let bothSides   = root.left != nil && root.right != nil
        let sideWidth   = bothSides ? (remaining / 2).rounded() : remaining
        let leftWidth   = root.left != nil ? sideWidth : 0

        if let left = root.left {
            applySlot(left, origin: CGPoint(x: origin.x, y: origin.y), elements: elements)
        }
        applySlot(root.center,
                  origin: CGPoint(x: origin.x + leftWidth, y: origin.y),
                  elements: elements)
        if let right = root.right {
            applySlot(right,
                      origin: CGPoint(x: origin.x + leftWidth + centerWidth, y: origin.y),
                      elements: elements)
        }
    }

    private func applySlot(_ slot: Slot, origin: CGPoint, elements: [WindowSlot: AXUIElement]) {
        switch slot {
        case .window(let w):
            guard let ax = elements[w] else { return }
            let g = w.gaps ? Config.innerGap : 0
            var pos  = CGPoint(x: (origin.x + g).rounded(), y: (origin.y + g).rounded())
            var size = CGSize(width: (w.width - g * 2).rounded(), height: (w.height - g * 2).rounded())
            if let posVal  = AXValueCreate(.cgPoint, &pos)  { AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, posVal) }
            if let sizeVal = AXValueCreate(.cgSize,  &size) { AXUIElementSetAttributeValue(ax, kAXSizeAttribute  as CFString, sizeVal) }
        case .stacking(let s):
            let raiseSequence: [WindowSlot] = s.order == .lifo ? s.children : s.children.reversed()
            for w in raiseSequence {
                guard let ax = elements[w] else { continue }
                let g = w.gaps ? Config.innerGap : 0
                let xOffset: CGFloat = s.align == .left ? 0 : s.width - w.width
                var pos  = CGPoint(x: (origin.x + xOffset + g).rounded(), y: (origin.y + g).rounded())
                var size = CGSize(width: (w.width - g * 2).rounded(), height: (w.height - g * 2).rounded())
                if let posVal  = AXValueCreate(.cgPoint, &pos)  { AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, posVal) }
                if let sizeVal = AXValueCreate(.cgSize,  &size) { AXUIElementSetAttributeValue(ax, kAXSizeAttribute  as CFString, sizeVal) }
                AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            }
        default:
            break
        }
    }
}
```

### 5. Create `ScrollingRootHandler`

Reads the focused window and delegates to `ScrollingTileService`.

```swift
// Entry point for creating or extending the scrolling root from the menu.
struct ScrollingRootHandler {

    static func scroll() {
        guard AXIsProcessTrusted() else { return }
        guard TileService.shared.snapshotVisibleRoot() == nil else { return }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString,
                                            &focusedWindow) == .success else { return }
        let axWindow = focusedWindow as! AXUIElement
        guard let screen = NSScreen.main else { return }

        var key = windowSlot(for: axWindow, pid: pid)
        key.preTileOrigin = readOrigin(of: axWindow)
        key.preTileSize   = readSize(of: axWindow)

        if ScrollingTileService.shared.snapshotVisibleScrollingRoot() != nil {
            ScrollingTileService.shared.addWindow(key, screen: screen)
        } else {
            ScrollingTileService.shared.createScrollingRoot(key: key, screen: screen)
        }
        ResizeObserver.shared.observe(window: axWindow, pid: pid, key: key)
        ReapplyHandler.reapplyAll()
    }
}
```

### 6. Update `LayoutService`

Add a scrolling layout pass after the existing tiling pass. Both are driven by the same `origin` (outer-gap-shifted).

```swift
func applyLayout(screen: NSScreen) {
    let visible       = screen.visibleFrame
    let primaryHeight = NSScreen.screens[0].frame.height
    let og     = Config.outerGaps
    let origin = CGPoint(x: visible.minX + og.left!, y: primaryHeight - visible.maxY + og.top!)
    let elements = ResizeObserver.shared.elements

    if let root = TileService.shared.snapshotVisibleRoot() {
        applyLayout(root, origin: origin, elements: elements)
    }
    if let root = ScrollingTileService.shared.snapshotVisibleScrollingRoot() {
        ScrollingLayoutService.shared.applyLayout(root: root, origin: origin, elements: elements)
    }
}
```

### 7. Update `UnnamedWindowManagerApp`

Add a "Scroll" button that is shown only when no tiling root is active. Place it in the group with Tile/Tile all.

```swift
if !menuState.isTiled {
    Button("Scroll") { ScrollingRootHandler.scroll() }
}
```

Insert after the existing Tile/Untile/Tile all/Untile all block, before `Reset layout`.

### 8. Update `WindowLister`

Extend the `.scrolling` branch in `logSlotTree()` to log each zone.

```swift
case .scrolling(let root):
    Logger.shared.log("scrolling root \(id.uuidString.prefix(8))  size=\(Int(root.width))x\(Int(root.height))")
    if let left = root.left  { logSlot(left,   depth: 1, label: "left")   }
    logSlot(root.center, depth: 1, label: "center")
    if let right = root.right { logSlot(right, depth: 1, label: "right")  }
```

`logSlot` may need an optional `label` parameter (or print it inline via prefix).

---

## Key Technical Notes

- `left` and `right` being `Slot?` instead of `Slot` is a breaking change to `ScrollingRootSlot`; since no code outside plan-13 stubs currently creates or reads these fields, compiler errors are the only risk and they'll be caught immediately.
- `visibleScrollingRootID()` duplicates the CGWindowList scan from `TileService.visibleRootID()`. Acceptable duplication for now; both scans are cheap and happen on layout passes.
- `ReapplyHandler.reapplyAll()` does not need changes: `LayoutService.applyLayout(screen:)` already gets called and now handles both root types. `leavesInVisibleRoot()` (tiling only) continues to govern `ResizeObserver.reapplying` and `PostResizeValidator` — scrolling root windows are exempt from those validators in this plan.
- `ResizeObserver.shared.observe(window:pid:key:)` must be called in the handler so the `elements` dict contains the AX element; otherwise `ScrollingLayoutService` cannot position the window.
- `menuState.isTiled` is `false` when a scrolling root is visible (since `snapshotVisibleRoot()` only returns tiling roots). The "Scroll" button therefore correctly appears when a scrolling root is active, enabling the add-window flow.
- Windows inside the scrolling root are never "tracked" by `TileService.isTracked()`, so `isFrontmostTiled` will be `false` and the menu will show "Tile" rather than "Untile" for a scrolling-root window. This is acceptable — untiling scrolling roots is a future plan.

---

## Verification

1. Launch the app with no windows tiled → menu shows "Scroll".
2. Focus a window → press "Scroll" → window fills 80% of screen width at the left edge.
3. Focus a different window → press "Scroll" again → first window moves to a 20%-wide left slot (as StackingSlot), second window fills the 80% center.
4. Focus a third window → press "Scroll" → third window becomes center, second joins the left StackingSlot (two windows stacked, both 20%-wide).
5. Tile a window (regular Tile button) → "Scroll" disappears from menu.
6. "Debug" log shows `scrolling root` entry with `left`, `center`, `right` zones printed.
7. Press "Refresh" → scrolling root re-lays out without error.
