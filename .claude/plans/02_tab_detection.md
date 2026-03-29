# Plan: 02_tab_detection — Detect native macOS tabs and treat as one window

## Checklist

- [x] Create TabDetector utility
- [x] Add `isTabbed` flag to WindowSlot
- [x] Filter tab duplicates in TileAllHandler
- [x] Detect tab-of-tiled-window in TileHandler and swap identity
- [x] Add tab swap operation to ResizeObserver
- [x] Add replaceLeafIdentity mutation to TilingTreeMutationService
- [x] Handle tab switches in pruneOffScreenWindows
- [x] Add AXUIElement lookup helper to AXHelpers

---

## Context / Problem

macOS supports native window tabs (Window > Merge All Windows, or the system
"Prefer tabs" setting). When two windows are merged into tabs, each tab retains
its own `CGWindowID` and `AXWindow` element, but they share the same window
frame. Both appear in `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` and
both are returned by `kAXWindowsAttribute`.

Currently the tiling manager treats each tab as a separate window. Tiling a
tabbed window creates multiple slots in the layout — one per tab — breaking it.

**Example from logs (pid 663 has two tiled tabs):**
```
horizontal  children=2
  window  fraction=0.5  pid=663  hash=252
  vertical  fraction=0.5  children=2
    window  fraction=0.5  pid=663  hash=1561    ← tab sibling, shouldn't be here
    window  fraction=0.5  pid=3064  hash=2924
```

**Goal:** Detect tab groups and treat them as a single tiled window. When the
user switches tabs on a tiled window, the layout stays unchanged — only the
window identity (hash) is swapped.

---

## macOS tab capability note

Native macOS tabs (`NSWindow` tab groups) expose each tab as a separate
`AXWindow` with its own `CGWindowID`. There is no standard AX attribute for
tab group membership.

**Detection heuristic:** Two `AXWindow` elements from the same PID with
identical `CGWindow` bounds (X, Y, Width, Height) are tab siblings. This is
reliable because native tabs share the exact same `NSWindow` frame (bit-identical
bounds). False positives (two separate windows at exactly the same position and
size) are extremely unlikely, especially after the tiler repositions them.

AeroSpace avoids this problem entirely because it was designed from the start
with the assumption that each `NSWindow` = one tiling unit. It has no explicit
tab detection.

---

## Files to create / modify

| File | Action |
|------|--------|
| `Services/Window/TabDetector.swift` | **New file** — tab group detection via CGWindow bounds |
| `Model/WindowSlot.swift` | Modify — add `isTabbed: Bool` flag |
| `Services/Handlers/TileAllHandler.swift` | Modify — filter tab duplicates before snapping |
| `Services/Handlers/TileHandler.swift` | Modify — swap identity when tiling a tab of an already-tiled window |
| `Services/Observation/ResizeObserver.swift` | Modify — add `swapTab` operation |
| `Services/Tiling/TilingTreeMutationService.swift` | Modify — add `replaceLeafIdentity` mutation |
| `Services/ReapplyHandler.swift` | Modify — detect tab switches in `pruneOffScreenWindows` |
| `Services/Window/AXHelpers.swift` | Modify — add `axWindow(forHash:pid:)` lookup helper |

---

## Implementation Steps

### 1. Create TabDetector utility

New file: `Services/Window/TabDetector.swift`

Queries `CGWindowListCopyWindowInfo` and groups same-PID windows by their bounds
to identify tab groups. Separate from `OnScreenWindowCache` because it needs
full bounds data, not just hashes.

```swift
/// Detects native macOS tab groups by identifying same-PID windows with identical CGWindow bounds.
struct TabDetector {

    struct WindowInfo {
        let wid: CGWindowID
        let pid: pid_t
        let bounds: CGRect
    }

    /// Returns tab sibling hashes for a given window, excluding itself.
    static func tabSiblingHashes(of hash: UInt, pid: pid_t) -> Set<UInt> {
        let infos = onScreenWindowInfos()
        guard let target = infos.first(where: { UInt($0.wid) == hash && $0.pid == pid })
        else { return [] }
        return Set(
            infos.filter { $0.pid == pid && $0.bounds == target.bounds && UInt($0.wid) != hash }
                 .map { UInt($0.wid) }
        )
    }

    /// Given a set of candidate CGWindowIDs for a single PID, returns the subset to keep
    /// after filtering out tab duplicates. Keeps the smallest wid per tab group.
    static func filterTabDuplicates(wids: Set<CGWindowID>, pid: pid_t) -> Set<CGWindowID> {
        let infos = onScreenWindowInfos().filter { $0.pid == pid && wids.contains($0.wid) }
        var grouped: [String: [CGWindowID]] = [:]
        for info in infos {
            let key = boundsKey(info.bounds)
            grouped[key, default: []].append(info.wid)
        }
        var keep = Set<CGWindowID>()
        for (_, group) in grouped {
            keep.insert(group.min()!)  // deterministic: smallest wid
        }
        return keep
    }

    private static func onScreenWindowInfos() -> [WindowInfo] {
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var result: [WindowInfo] = []
        for info in list {
            guard let layer  = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid    = info[kCGWindowOwnerPID as String] as? Int,
                  let wid    = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"],
                  pid_t(pid) != ownPID
            else { continue }
            result.append(WindowInfo(wid: wid, pid: pid_t(pid),
                                     bounds: CGRect(x: x, y: y, width: w, height: h)))
        }
        return result
    }

    private static func boundsKey(_ b: CGRect) -> String {
        "\(b.origin.x)-\(b.origin.y)-\(b.width)-\(b.height)"
    }
}
```

### 2. Add `isTabbed` flag to WindowSlot

```swift
struct WindowSlot: Hashable, Sendable {
    // ... existing fields ...
    var isTabbed: Bool = false   // does NOT participate in == / hash(into:)
}
```

This flag marks that the window was detected as part of a tab group. Used by
`pruneOffScreenWindows` to know it should check for tab siblings before removing
the slot.

### 3. Filter tab duplicates in TileAllHandler

After building `pidToWindowIDs` from CGWindowList, filter each PID's window set
through `TabDetector.filterTabDuplicates()`. This keeps one CGWindowID per tab
group before AX enumeration begins.

```swift
// After building pidToWindowIDs, filter tab duplicates per PID:
for (pid, wids) in pidToWindowIDs {
    pidToWindowIDs[pid] = TabDetector.filterTabDuplicates(wids: wids, pid: pid)
}
```

When creating the WindowSlot for a kept tab, set `isTabbed = true` if the
original set was larger than the filtered set for that PID (meaning tabs were
detected).

### 4. Detect tab-of-tiled-window in TileHandler

In `tile()`, after building the `WindowSlot` key but before calling `snap()`:

1. Compute `tabSiblingHashes(of: key.windowHash, pid: pid)`.
2. For each sibling hash, build a temporary `WindowSlot` and check
   `TilingRootStore.shared.isTracked()`.
3. If a sibling is already tiled: call `ResizeObserver.shared.swapTab()` to
   replace the old tab's identity with the new one, then return (skip snap).

```swift
let siblings = TabDetector.tabSiblingHashes(of: key.windowHash, pid: pid)
for siblingHash in siblings {
    let siblingKey = WindowSlot(pid: pid, windowHash: siblingHash,
                                id: UUID(), parentId: UUID(), order: 0, size: .zero)
    if TilingRootStore.shared.isTracked(siblingKey) {
        ResizeObserver.shared.swapTab(oldKey: siblingKey,
                                      newWindow: axWindow, newHash: key.windowHash)
        ReapplyHandler.reapplyAll()
        return
    }
}
```

### 5. Add tab swap to ResizeObserver

New method on `ResizeObserver`:

```swift
func swapTab(oldKey: WindowSlot, newWindow: AXUIElement, newHash: UInt) {
    let pid = oldKey.pid

    // 1. Remove old AX notifications
    if let axObs = observers[pid], let oldElement = elements[oldKey] {
        AXObserverRemoveNotification(axObs, oldElement, kAXWindowMovedNotification as CFString)
        AXObserverRemoveNotification(axObs, oldElement, kAXWindowResizedNotification as CFString)
        AXObserverRemoveNotification(axObs, oldElement, kAXWindowMiniaturizedNotification as CFString)
        AXObserverRemoveNotification(axObs, oldElement, kElementDestroyed)
    }

    // 2. Clean up old tracking (but don't touch the slot tree or layout)
    reapplyScheduler.cancel(key: oldKey)
    reapplying.remove(oldKey)
    elements.removeValue(forKey: oldKey)
    keysByHash.removeValue(forKey: oldKey.windowHash)
    keysByPid[pid]?.remove(oldKey)

    // 3. Update slot tree identity
    let newKey = WindowSlot(pid: pid, windowHash: newHash,
                            id: UUID(), parentId: UUID(), order: 0, size: .zero,
                            isTabbed: true)
    SharedRootStore.shared.queue.sync(flags: .barrier) {
        // find the tiling root containing oldKey and replace leaf identity
        for (id, rootSlot) in SharedRootStore.shared.roots {
            guard case .tiling(var root) = rootSlot else { continue }
            if TilingTreeMutationService().replaceLeafIdentity(
                oldKey: oldKey, newPid: pid, newHash: newHash, in: &root
            ) {
                SharedRootStore.shared.roots[id] = .tiling(root)
                break
            }
        }
    }

    // 4. Register new window with new identity
    observe(window: newWindow, pid: pid, key: newKey)
}
```

### 6. Add `replaceLeafIdentity` to TilingTreeMutationService

New mutation that finds a leaf by `oldKey` and replaces its `pid` and
`windowHash` without changing position, size, fraction, or tree structure.

```swift
/// Replaces the identity (pid + windowHash) of a leaf without changing its layout.
/// Returns true if the leaf was found and updated.
@discardableResult
func replaceLeafIdentity(
    oldKey: WindowSlot, newPid: pid_t, newHash: UInt,
    in root: inout TilingRootSlot
) -> Bool {
    updateLeaf(oldKey, in: &root) { w in
        w = WindowSlot(pid: newPid, windowHash: newHash,
                       id: w.id, parentId: w.parentId,
                       order: w.order, size: w.size,
                       gaps: w.gaps, fraction: w.fraction,
                       preTileOrigin: w.preTileOrigin,
                       preTileSize: w.preTileSize,
                       isTabbed: true)
    }
}
```

This reuses the existing `updateLeaf(_:in:update:)` infrastructure.

### 7. Handle tab switches in pruneOffScreenWindows

In `ReapplyHandler.pruneOffScreenWindows()`, before removing a window that
disappeared from the on-screen set:

1. Check `TabDetector.tabSiblingHashes()` for the disappearing window.
2. If a sibling is on-screen: this is a tab switch, not a window close.
3. Look up the sibling's `AXUIElement` via `axWindow(forHash:pid:)`.
4. Call `ResizeObserver.shared.swapTab()` instead of removing.

```swift
for leaf in leaves {
    guard case .window(let w) = leaf else { continue }
    guard !onScreen.contains(w.windowHash) else { continue }

    // Check for tab switch before pruning
    let siblings = TabDetector.tabSiblingHashes(of: w.windowHash, pid: w.pid)
    let activeSibling = siblings.first { onScreen.contains($0) }
    if let siblingHash = activeSibling,
       let siblingAX = axWindow(forHash: siblingHash, pid: w.pid) {
        ResizeObserver.shared.swapTab(oldKey: w, newWindow: siblingAX, newHash: siblingHash)
        continue   // skip removal
    }

    // Normal prune path
    Logger.shared.log("pruning off-screen window: pid=\(w.pid) hash=\(w.windowHash)")
    ResizeObserver.shared.stopObserving(key: w, pid: w.pid)
    TilingSnapService.shared.removeAndReflow(w, screen: screen)
}
```

### 8. Add AXUIElement lookup helper to AXHelpers

New function in `AXHelpers.swift` to find an AX window element by its
CGWindowID hash and PID:

```swift
/// Returns the AXUIElement for the window with the given CGWindowID hash, or nil.
func axWindow(forHash hash: UInt, pid: pid_t) -> AXUIElement? {
    let axApp = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let axWindows = windowsRef as? [AXUIElement] else { return nil }
    return axWindows.first { windowID(of: $0).map(UInt.init) == hash }
}
```

---

## Key Technical Notes

- CGWindow bounds comparison uses exact float equality. Native macOS tabs share
  the same `NSWindow` frame, so bounds are bit-identical.
- `TabDetector` does its own `CGWindowListCopyWindowInfo` query because
  `OnScreenWindowCache` only stores hashes, not bounds.
- The tab swap must update BOTH ResizeObserver tracking maps AND the slot tree's
  WindowSlot identity. Missing either causes dangling references.
- `WindowSlot.isTabbed` does not participate in `==` or `hash(into:)`.
- When a tab is dragged out of a tab group, it gets a new position and is
  correctly treated as a separate window (bounds no longer match).
- The `replaceLeafIdentity` mutation preserves all layout properties (size,
  fraction, order, gaps, preTile values) — only pid and windowHash change.
- `filterTabDuplicates` uses smallest CGWindowID as tie-breaker for determinism.

---

## Verification

1. Open Finder > create two windows > Window > Merge All Windows > Tile All → only one slot in layout
2. Switch tabs on a tiled tabbed Finder window → layout unchanged, new tab shown in same slot
3. Tile All with a mix of tabbed and non-tabbed windows → correct count of slots
4. Manually tile (hotkey) the inactive tab of an already-tiled window → swap occurs, no new slot
5. Drag a tab out of a tiled tabbed window → dragged-out window is independent
6. Close the active tab of a tiled tabbed window → next tab takes over the slot (or slot removed if last tab)
7. Regression: tile/untile non-tabbed windows works exactly as before
