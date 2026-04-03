# Plan: 02_settle_poller — Replace hardcoded delays with polling-based settle detection

## Checklist

- [ ] Create `SettlePoller` utility in Services/Window/
- [ ] Replace AutoModeHandler 0.3s delay with settle polling
- [ ] Replace ReapplyHandler 0.3s delay (pass 2→3) with settle polling
- [ ] Replace PostResizeValidator 0.2s delay with settle polling
- [ ] Replace FocusObserver 0.15s retry with settle polling
- [ ] Remove TileAllHandler 0.5s notification delay
- [ ] Update CODE.md with new file
- [ ] Update LATER.md (mark resolved or remove)

---

## Context / Problem

Five `asyncAfter` delays in the codebase use hardcoded magic numbers instead of adapting to `Config.animationDuration`. If animation speed is changed, these fixed waits can fire too early (before windows settle) or too late (wasted time). LATER.md documents these.

The fix: replace fixed delays with a polling service that checks a condition at short intervals, completing as soon as the condition is met or a timeout (`Config.animationDuration + 0.1`) is reached. This is both faster (returns immediately when settled) and safer (scales with config).

Case 5 (TileAllHandler notification) simply removes the delay — the notification should post immediately.

---

## Settle conditions per call site

| Call site | "Settled" condition | Notes |
|-----------|-------------------|-------|
| **AutoModeHandler:107** | Window's actual AX size matches its target slot size (within 2pt) | Same tolerance PostResizeValidator uses |
| **ReapplyHandler:54** | All windows' actual sizes match targets (within 2pt) | This is the pass-2→pass-3 gap; polls all tracked windows |
| **PostResizeValidator:52** | Window sizes stopped changing between two consecutive reads | Two reads are equal → safe to clear `reapplying` |
| **FocusObserver:107** | Window hash appears in `OnScreenWindowCache.visibleHashes()` | Must invalidate cache each poll tick |

---

## Files to create / modify

| File | Action |
|------|--------|
| `Services/Window/SettlePoller.swift` | **New file** — generic poll-until-settled utility |
| `Services/AutoMode/AutoModeHandler.swift` | Modify — replace `asyncAfter(0.3)` with `SettlePoller` |
| `Services/ReapplyHandler.swift` | Modify — replace `asyncAfter(0.3)` at line 54 with `SettlePoller` |
| `Services/Window/PostResizeValidator.swift` | Modify — replace `asyncAfter(0.2)` with `SettlePoller` |
| `Services/Observation/FocusObserver.swift` | Modify — replace `asyncAfter(0.15)` retry with `SettlePoller` |
| `Services/Handlers/TileAllHandler.swift` | Modify — remove `asyncAfter(0.5)`, post notification inline |
| `CODE.md` | Modify — add `SettlePoller.swift` entry |

---

## Implementation Steps

### 1. Create `SettlePoller`

A small enum with a single static method that polls a condition closure on the main queue at a fixed interval, calling a completion when the condition returns `true` or the timeout expires.

```swift
// Polls a condition at a fixed interval, firing the completion when
// the condition is met or the timeout elapses.
enum SettlePoller {

    private static let pollInterval: TimeInterval = 0.02  // 20ms

    /// Polls `condition` every 20ms on the main queue.
    /// Calls `completion(true)` when `condition` returns `true`,
    /// or `completion(false)` when `timeout` seconds have elapsed.
    static func poll(
        timeout: TimeInterval = Config.animationDuration + 0.1,
        condition: @escaping () -> Bool,
        completion: @escaping (_ settled: Bool) -> Void
    ) {
        let start = DispatchTime.now()
        let timeoutNanos = UInt64(timeout * 1_000_000_000)

        func tick() {
            if condition() {
                completion(true)
                return
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            if elapsed >= timeoutNanos {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                tick()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            tick()
        }
    }
}
```

The default timeout uses `Config.animationDuration + 0.1` so it automatically scales with the user's configured animation speed.

### 2. Replace AutoModeHandler delay

Current (line 107):
```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    PostResizeValidator.checkAndFixRefusals(windows: allKeys, screen: screen)
}
```

Replace with polling that checks whether all windows have reached their target sizes:

```swift
SettlePoller.poll(condition: {
    allKeys.allSatisfy { key in
        guard let axEl = ResizeObserver.shared.elements[key],
              let actual = readSize(of: axEl) else { return false }
        let gap = key.gaps ? Config.innerGap * 2 : 0
        return abs(actual.width - (key.size.width - gap)) <= 2
            && abs(actual.height - (key.size.height - gap)) <= 2
    }
}) { _ in
    PostResizeValidator.checkAndFixRefusals(windows: allKeys, screen: screen)
}
```

The validator runs regardless of whether polling settled or timed out — it must still fix refusals.

### 3. Replace ReapplyHandler pass-2→pass-3 delay

Current (line 54):
```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    // pass 3 validation
}
```

Replace with the same frame-match polling pattern as step 2, checking `allWindows` against their target sizes. The completion block runs the pass-3 logic (check refusals → untile persistent ones).

### 4. Replace PostResizeValidator delay

Current (line 52):
```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    observer.reapplying.subtract(allTracked)
}
```

Replace with polling that checks whether window sizes have stabilized (two consecutive reads return the same value):

```swift
var lastSizes: [WindowSlot: CGSize] = [:]
SettlePoller.poll(condition: {
    var stable = true
    for key in allTracked {
        guard let axEl = observer.elements[key],
              let size = readSize(of: axEl) else { continue }
        if lastSizes[key] != size {
            stable = false
        }
        lastSizes[key] = size
    }
    return stable && !lastSizes.isEmpty
}) { _ in
    observer.reapplying.subtract(allTracked)
}
```

First tick populates `lastSizes`; second tick compares. If sizes match → settled.

### 5. Replace FocusObserver retry

Current (line 104-108):
```swift
if !swapped, !managedSiblings.isEmpty {
    let work = DispatchWorkItem { [weak self] in self?.applyDim(pid: pid) }
    retryWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    return
}
```

Replace with polling that invalidates OnScreenWindowCache each tick and checks if the hash appears:

```swift
if !swapped, !managedSiblings.isEmpty {
    retryWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
        SettlePoller.poll(condition: {
            OnScreenWindowCache.invalidate()
            let onScreen = OnScreenWindowCache.visibleHashes()
            return onScreen.contains(hash)
        }) { settled in
            guard settled else { return }
            self?.applyDim(pid: pid)
        }
    }
    retryWorkItem = work
    DispatchQueue.main.async(execute: work)
    return
}
```

The `retryWorkItem` cancellation pattern is preserved. If the hash never appears within the timeout, we give up silently (same as the old single-retry behavior, but more thorough).

### 6. Remove TileAllHandler notification delay

Current (line 78):
```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    // post notification
}
```

Replace with immediate notification — move the notification code inline, remove the `asyncAfter` wrapper.

### 7. Update CODE.md and LATER.md

Add `SettlePoller.swift` to the `Services/Window/` table in CODE.md. Mark all 5 items in LATER.md as resolved or remove the file.

---

## Key Technical Notes

- `SettlePoller.poll` always fires the completion (with `settled: true` or `false`), so callers can proceed regardless — this is important for PostResizeValidator which must still run even after timeout.
- The 20ms poll interval is fast enough to detect frame changes mid-animation but not so fast that it hammers the AX API. CVDisplayLink would be more precise but overkill for these one-shot waits.
- `OnScreenWindowCache.invalidate()` must be called each tick in the FocusObserver case, otherwise the 50ms cache could mask a just-appeared window.
- `Config.animationDuration` defaults to 0.15s, so the default timeout is 0.25s — faster than most of the old hardcoded delays.
- The `retryWorkItem` in FocusObserver can be cancelled by a subsequent focus change, which naturally cancels the poll (the DispatchWorkItem is cancelled, and the closure captures `[weak self]`).

---

## Verification

1. Set `animationDuration: 0.15` in config → snap a window → it snaps and PostResizeValidator runs within ~0.25s
2. Set `animationDuration: 0.5` → snap a window → validator waits longer, still catches refusals
3. Open a refusing app (e.g. Terminal with min-size) → auto-snap it → notification appears, window untiled after persistent refusal
4. Switch tabs in Safari/Chrome with managed windows → tab swap detected, layout reapplied
5. Run Tile All → notification appears immediately with correct count
6. Resize a tiled window via drag → reapply settles correctly, no flicker
