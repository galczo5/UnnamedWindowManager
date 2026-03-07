# Plan: 09_prune_stale_slots — Prune ghost window slots on terminal tab switch

## Checklist

- [ ] Add `allWindowIDs(for:)` helper to AutoSnapObserver
- [ ] Add `pruneStaleSlots(for:)` method to AutoSnapObserver
- [ ] Call pruning before auto-snap in `snapFocusedWindow`
- [ ] Add log line for pruned slots
- [ ] Manual verification with terminal tab switching

---

## Context / Problem

When the user switches tabs in a terminal, `kAXWindowCreatedNotification` fires. The auto-snap flow creates a new `WindowSlot` with the new tab's CGWindowID and inserts it into the slot tree. However, the old tab's slot is never removed because `kAXUIElementDestroyedNotification` does not fire — the old AX element still exists in the accessibility hierarchy, just off-screen.

Each tab switch adds a ghost slot. The tree accumulates duplicate entries for the same pid, each taking up layout space, producing empty gaps on screen.

**Current behaviour**: 3 windows on screen, 4 leaves in slot tree, visible empty space.

**Goal**: Before inserting a new window for a pid, detect and remove any tracked slots for that pid whose CGWindowID no longer exists in the system window list.

---

## Off-screen detection

`CGWindowListCopyWindowInfo(.optionAll, ...)` returns all windows owned by all apps, including minimized and off-screen windows. Using `.optionAll` (not `.optionOnScreenOnly`) ensures we never accidentally prune a minimized window that the user intends to keep — its CGWindowID still appears in the full list. Only windows whose CGWindowID is truly gone (e.g. a tab that was replaced) get pruned.

Safety guard: if the CGWindowList query returns zero IDs for the pid, skip pruning entirely to avoid over-deletion in edge cases (e.g. CGWindowList API failure).

---

## Files to create / modify

| File | Action |
|------|--------|
| `UnnamedWindowManager/Observation/AutoSnapObserver.swift` | Modify — add pruning logic before auto-snap |

---

## Implementation Steps

### 1. Add `allWindowIDs(for:)` helper

Private method on `AutoSnapObserver` that queries all CGWindowIDs owned by a given pid.

```swift
private func allWindowIDs(for pid: pid_t) -> Set<UInt> {
    guard let list = CGWindowListCopyWindowInfo(
        [.excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return [] }
    var ids = Set<UInt>()
    for info in list {
        guard let p = info[kCGWindowOwnerPID as String] as? Int, pid_t(p) == pid,
              let wid = info[kCGWindowNumber as String] as? CGWindowID
        else { continue }
        ids.insert(UInt(wid))
    }
    return ids
}
```

Note: passing no `.option*` flags defaults to all windows. The key point is NOT using `.optionOnScreenOnly` so minimized windows are preserved.

### 2. Add `pruneStaleSlots(for:)` method

Iterates tracked slots for the pid, removes any whose `windowHash` is absent from the system window list.

```swift
private func pruneStaleSlots(for pid: pid_t) {
    guard let trackedKeys = ResizeObserver.shared.keysByPid[pid], !trackedKeys.isEmpty else { return }
    let knownWIDs = allWindowIDs(for: pid)
    guard !knownWIDs.isEmpty else { return }
    let screen = NSScreen.main
    for key in trackedKeys {
        guard !knownWIDs.contains(key.windowHash) else { continue }
        Logger.shared.log("pruning stale slot: pid=\(pid) hash=\(key.windowHash)")
        ResizeObserver.shared.stopObserving(key: key, pid: pid)
        if let screen {
            SnapService.shared.removeAndReflow(key, screen: screen)
        } else {
            SnapService.shared.remove(key)
        }
    }
}
```

### 3. Call from `snapFocusedWindow`

Insert the call immediately before `SnapHandler.snapLeft(...)`:

```swift
// existing line:
Logger.shared.log("autoSnap triggered for pid=\(pid)")
// add:
pruneStaleSlots(for: pid)
// existing line:
SnapHandler.snapLeft(window: window, pid: pid)
```

---

## Key Technical Notes

- `ResizeObserver.shared.keysByPid[pid]` returns a `Set<WindowSlot>` value copy, so mutating the observer inside the loop is safe.
- `stopObserving` removes AX notification registrations and cleans up `elements`/`keysByPid` maps.
- `removeAndReflow` uses a `store.queue.sync(flags: .barrier)` block; `snapLeft` → `snap` uses another. Both run sequentially on the main thread — no deadlock risk since `store.queue` is a concurrent dispatch queue (sync+barrier serializes).
- The pruning only runs in the auto-snap path (`snapFocusedWindow`). `OrganizeHandler.organize()` already filters to on-screen CGWindowIDs so it cannot create stale slots.
- Windows with pointer-based hashes (fallback when `_AXUIElementGetWindow` fails) will also be pruned since their hash can never match a CGWindowID. This is correct — such windows are already broken for `visibleRootID()` matching.

---

## Verification

1. Open a terminal with tabs and snap three windows via organize
2. Switch a tab in the terminal
3. Confirm the slot tree still has exactly 3 leaves (check log output for `logSlotTree`)
4. Confirm the pruning log line appears: `pruning stale slot: pid=... hash=...`
5. Confirm no empty space in the layout
6. Switch tabs multiple times rapidly — tree should never accumulate ghost slots
7. Minimize a terminal window, switch tabs in another terminal window — minimized window should remain in the tree
8. Open a second window in the same app (not a tab) — both windows should remain tracked
