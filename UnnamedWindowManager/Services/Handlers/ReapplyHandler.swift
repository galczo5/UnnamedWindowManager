import AppKit
import ApplicationServices

// Coordinates layout reapplication, drop-target detection, and size clamping.
struct ReapplyHandler {

    /// Reapplies the layout for a single already-tracked window.
    /// No-op if the window is no longer in the slot tree.
    static func reapply(window: AXUIElement, key: WindowSlot) {
        guard TilingRootStore.shared.isTracked(key) || ScrollingRootStore.shared.isTracked(key)
        else { return }
        guard let screen = NSScreen.main else { return }
        TilingLayoutService.shared.applyLayout(screen: screen)
    }

    /// Reapplies the layout for all tiled windows, debounced to 10 ms.
    /// Multiple calls within 10 ms collapse into one execution. After the layout
    /// runs, WindowPostResizeValidator fires 300 ms later to catch any refusing windows.
    ///
    /// Each call bumps a monotonic generation. All deferred stages scheduled by this
    /// call capture that generation and bail if a newer call has advanced it, so
    /// rapid repeated invocations (fast moves/swaps during an in-flight reapply)
    /// do not let stale tails stomp on the new layout. Pre-reapply frames captured
    /// for the first in-flight generation are preserved across overlapping generations
    /// so mid-animation AX reads never pollute user-intent calculations.
    static func reapplyAll(scrollingSidesPositionOnly: Bool = false) {
        pendingLayout?.cancel()
        pendingClearReapplying?.cancel()
        pendingValidator?.cancel()

        currentGeneration &+= 1
        let gen = currentGeneration

        let work = DispatchWorkItem {
            guard gen == Self.currentGeneration else { return }
            guard let screen = NSScreen.main else { return }
            pruneOffScreenWindows(screen: screen)
            let tilingLeaves = TilingRootStore.shared.leavesInVisibleRoot()
            let scrollingLeaves = ScrollingRootStore.shared.leavesInVisibleScrollingRoot()
            let allWindows = Set((tilingLeaves + scrollingLeaves).compactMap { leaf -> WindowSlot? in
                if case .window(let w) = leaf { return w }
                return nil
            })

            // Capture pre-reapply frames only for keys not already tracked by an
            // earlier in-flight generation. Preserving the earlier frame means a
            // user gesture arriving mid-animation sees the frame the user actually
            // saw, not whatever the animation is interpolating.
            let newKeys = allWindows.subtracting(Self.activeSnapshot)
            for key in newKeys {
                guard let ax = WindowTracker.shared.elements[key] else { continue }
                if let origin = readOrigin(of: ax), let size = readSize(of: ax) {
                    WindowTracker.shared.preReapplyFrames[key] = CGRect(origin: origin, size: size)
                }
            }
            WindowTracker.shared.reapplying.formUnion(allWindows)
            Self.activeSnapshot.formUnion(allWindows)

            TilingLayoutService.shared.applyLayout(
                screen: screen, scrollingSidesPositionOnly: scrollingSidesPositionOnly)

            let animDur = Config.animationDuration

            let clearWork = DispatchWorkItem {
                guard gen == Self.currentGeneration else { return }
                WindowTracker.shared.reapplying.subtract(Self.activeSnapshot)
                for key in Self.activeSnapshot {
                    WindowTracker.shared.preReapplyFrames.removeValue(forKey: key)
                }
                Self.activeSnapshot = []
            }
            Self.pendingClearReapplying = clearWork
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.2, animDur + 0.05), execute: clearWork)

            let validatorWork = DispatchWorkItem {
                guard gen == Self.currentGeneration else { return }
                runPostLayoutValidator(generation: gen)
            }
            Self.pendingValidator = validatorWork
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.3, animDur + 0.1), execute: validatorWork)

            DispatchQueue.main.async {
                TileStateChangedObserver.shared.notify(TileStateChangedEvent())
            }
        }
        pendingLayout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: work)
    }

    private static func runPostLayoutValidator(generation gen: UInt64) {
        guard let screen = NSScreen.main else { return }
        let currentLeaves = TilingRootStore.shared.leavesInVisibleRoot()
            + ScrollingRootStore.shared.leavesInVisibleScrollingRoot()
        let current = Set(currentLeaves.compactMap { slot -> WindowSlot? in
            if case .window(let w) = slot { return w }
            return nil
        })

        // Snapshot expected slot sizes at pass2 time; pass3 compares against these
        // to skip untile for keys whose slot has been moved/resized by a newer op.
        var expectedSizes: [WindowSlot: CGSize] = [:]
        for key in current { expectedSizes[key] = key.size }

        let pass2Refusals = WindowPostResizeValidator.checkAndFixRefusals(windows: current, screen: screen)

        for key in pass2Refusals {
            let appName = NSRunningApplication(processIdentifier: key.pid)?.localizedName ?? "Unknown"
            NotificationService.shared.post(
                title: "Window refused to resize",
                body: "\(appName) could not be resized to fit its slot."
            )
        }

        guard !pass2Refusals.isEmpty else { return }

        let observer = WindowTracker.shared
        SettlePoller.poll(condition: {
            pass2Refusals.allSatisfy { key in
                guard let axEl = observer.elements[key],
                      let actual = readSize(of: axEl) else { return false }
                let gap = key.gaps ? Config.innerGap * 2 : 0
                return abs(actual.width  - (key.size.width  - gap)) <= 2
                    && abs(actual.height - (key.size.height - gap)) <= 2
            }
        }) { _ in
            guard gen == Self.currentGeneration else { return }
            guard let screen = NSScreen.main else { return }

            let liveLeaves = TilingRootStore.shared.leavesInVisibleRoot()
                + ScrollingRootStore.shared.leavesInVisibleScrollingRoot()
            let live = Set(liveLeaves.compactMap { slot -> WindowSlot? in
                if case .window(let w) = slot { return w }
                return nil
            })

            let pass3Refusals = WindowPostResizeValidator.checkAndFixRefusals(windows: live, screen: screen)
            let persistent = pass2Refusals.intersection(pass3Refusals)
            guard !persistent.isEmpty else { return }

            var didUntile = false
            for key in persistent {
                guard TilingRootStore.shared.isTracked(key)
                        || ScrollingRootStore.shared.isTracked(key) else { continue }
                // Stale-geometry guard: the key's slot must still be the same size
                // it was at pass2; otherwise a newer op has re-slotted this window
                // and the next generation's reapply will validate the new slot.
                guard let expected = expectedSizes[key], expected == key.size else { continue }

                UntileHandler.untileByKey(key, screen: screen)
                didUntile = true
                let appName = NSRunningApplication(processIdentifier: key.pid)?.localizedName ?? "Unknown"
                NotificationService.shared.post(
                    title: "Window untiled",
                    body: "\(appName) was untiled because it repeatedly refused to resize."
                )
            }
            if didUntile {
                ReapplyHandler.reapplyAll()
            }
        }
    }

    private static var currentGeneration: UInt64 = 0
    private static var activeSnapshot: Set<WindowSlot> = []
    private static var pendingLayout: DispatchWorkItem?
    private static var pendingClearReapplying: DispatchWorkItem?
    private static var pendingValidator: DispatchWorkItem?

    /// Returns the drop target (window + zone) under the current mouse cursor,
    /// excluding `draggedKey` itself. Returns `nil` when the cursor is not over any
    /// managed window. `.center` triggers a swap; directional zones trigger insertion.
    static func findDropTarget(forKey draggedKey: WindowSlot) -> DropTarget? {
        guard let screen = NSScreen.main else { return nil }
        let cursor = NSEvent.mouseLocation           // AppKit coords (bottom-left origin)
        let screenHeight = NSScreen.screens[0].frame.height
        // Use precomputed slot-tree frames instead of live AX reads.
        let frames = TilingLayoutService.shared.computeFrames(screen: screen)

        for (w, axFrame) in frames {
            guard w != draggedKey else { continue }

            // AX coords: top-left origin, y increases downward.
            // AppKit coords: bottom-left origin, y increases upward.
            let appKitY = screenHeight - axFrame.origin.y - axFrame.height
            let frame = CGRect(x: axFrame.origin.x, y: appKitY, width: axFrame.width, height: axFrame.height)

            guard frame.contains(cursor) else { continue }

            // Left/right are checked before top/bottom so corners prefer horizontal zones.
            if cursor.x < frame.minX + frame.width * Config.dropZoneLeftFraction {
                return DropTarget(window: w, zone: .left)
            }
            if cursor.x > frame.maxX - frame.width * Config.dropZoneRightFraction {
                return DropTarget(window: w, zone: .right)
            }
            if cursor.y > frame.maxY - frame.height * Config.dropZoneTopFraction {
                return DropTarget(window: w, zone: .top)
            }
            if cursor.y < frame.minY + frame.height * Config.dropZoneBottomFraction {
                return DropTarget(window: w, zone: .bottom)
            }
            return DropTarget(window: w, zone: .center)
        }
        return nil
    }

    /// Removes tracked windows whose CGWindowID is no longer on screen.
    /// Catches windows that moved to another Space or were closed without firing a destroy notification.
    /// Also consolidates multiple tiling roots that ended up on the same desktop.
    private static func pruneOffScreenWindows(screen: NSScreen) {
        TilingService.shared.consolidateVisibleRoots(screen: screen)
        let onScreen = onScreenWindowIDs()
        guard !onScreen.isEmpty else { return }
        let leaves = TilingRootStore.shared.leavesInVisibleRoot()
        for leaf in leaves {
            guard case .window(let w) = leaf else { continue }
            guard !onScreen.contains(pid: w.pid, hash: w.windowHash) else { continue }

            // Check for tab switch: enumerate AX windows for the same PID and look for
            // an unmanaged on-screen sibling that replaced this window (inactive tab).
            var didSwap = false
            let axApp = AXUIElementCreateApplication(w.pid)
            var wRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wRef) == .success,
               let axWindows = wRef as? [AXUIElement] {
                for ax in axWindows {
                    guard let wid = windowID(of: ax).map(UInt.init),
                          wid != w.windowHash,
                          onScreen.contains(pid: w.pid, hash: wid),
                          WindowTracker.shared.keysByHash[wid] == nil else { continue }
                    WindowEventRouter.shared.swapTab(oldKey: w, newWindow: ax, newHash: wid)
                    didSwap = true
                    break
                }
            }
            if didSwap { continue }

            UntileHandler.untileByKey(w, screen: screen)
        }
        let scrollingLeaves = ScrollingRootStore.shared.leavesInVisibleScrollingRoot()
        for leaf in scrollingLeaves {
            guard case .window(let w) = leaf else { continue }
            guard !onScreen.contains(pid: w.pid, hash: w.windowHash) else { continue }

            var didSwap = false
            let axApp = AXUIElementCreateApplication(w.pid)
            var wRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wRef) == .success,
               let axWindows = wRef as? [AXUIElement] {
                for ax in axWindows {
                    guard let wid = windowID(of: ax).map(UInt.init),
                          wid != w.windowHash,
                          onScreen.contains(pid: w.pid, hash: wid),
                          WindowTracker.shared.keysByHash[wid] == nil else { continue }
                    WindowEventRouter.shared.swapTab(oldKey: w, newWindow: ax, newHash: wid)
                    didSwap = true
                    break
                }
            }
            if didSwap { continue }

            UntileHandler.untileByKey(w, screen: screen)
        }
    }

    private static func onScreenWindowIDs() -> Set<OnScreenWindow> {
        WindowOnScreenCache.visibleSet()
    }

    /// Returns `size` clamped to the per-screen maximums defined in `Config`.
    static func clampSize(_ size: CGSize, screen: NSScreen) -> CGSize {
        let visible = screen.visibleFrame
        let maxW = visible.width  * Config.maxWidthFraction
        let og = Config.outerGaps
        let maxH = visible.height * Config.maxHeightFraction - og.top! - og.bottom!
        return CGSize(
            width:  min(size.width,  maxW),
            height: min(size.height, maxH)
        )
    }
}
