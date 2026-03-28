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
        LayoutService.shared.clearCache(for: key)
        LayoutService.shared.applyLayout(screen: screen)
    }

    /// Reapplies the layout for all tiled windows, debounced to 10 ms.
    /// Multiple calls within 10 ms collapse into one execution. After the layout
    /// runs, PostResizeValidator fires 300 ms later to catch any refusing windows.
    static func reapplyAll() {
        pendingLayout?.cancel()
        let work = DispatchWorkItem {
            guard let screen = NSScreen.main else { return }
            LayoutService.shared.clearCache()
            ScrollingLayoutService.shared.clearCache()
            pruneOffScreenWindows(screen: screen)
            let tilingLeaves = TilingRootStore.shared.leavesInVisibleRoot()
            let scrollingLeaves = ScrollingRootStore.shared.leavesInVisibleScrollingRoot()
            let allWindows = Set((tilingLeaves + scrollingLeaves).compactMap { leaf -> WindowSlot? in
                if case .window(let w) = leaf { return w }
                return nil
            })
            ResizeObserver.shared.reapplying.formUnion(allWindows)
            LayoutService.shared.applyLayout(screen: screen)
            WindowVisibilityManager.shared.applyVisibility()
            let animDur = Config.animationDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.2, animDur + 0.05)) {
                ResizeObserver.shared.reapplying.subtract(allWindows)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.3, animDur + 0.1)) {
                guard let screen = NSScreen.main else { return }
                let pass2Refusals = PostResizeValidator.checkAndFixRefusals(windows: allWindows, screen: screen)

                for key in pass2Refusals {
                    let appName = NSRunningApplication(processIdentifier: key.pid)?.localizedName ?? "Unknown"
                    NotificationService.shared.post(
                        title: "Window refused to resize",
                        body: "\(appName) could not be resized to fit its slot."
                    )
                }

                guard !pass2Refusals.isEmpty else { return }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let screen = NSScreen.main else { return }
                    let pass3Refusals = PostResizeValidator.checkAndFixRefusals(windows: allWindows, screen: screen)
                    let persistent = pass2Refusals.intersection(pass3Refusals)
                    guard !persistent.isEmpty else { return }

                    for key in persistent {
                        UntileHandler.untileByKey(key, screen: screen)
                        let appName = NSRunningApplication(processIdentifier: key.pid)?.localizedName ?? "Unknown"
                        NotificationService.shared.post(
                            title: "Window untiled",
                            body: "\(appName) was untiled because it repeatedly refused to resize."
                        )
                    }
                    ReapplyHandler.reapplyAll()
                }
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .tileStateChanged, object: nil)
            }
        }
        pendingLayout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: work)
    }

    private static var pendingLayout: DispatchWorkItem?

    /// Returns the drop target (window + zone) under the current mouse cursor,
    /// excluding `draggedKey` itself. Returns `nil` when the cursor is not over any
    /// managed window. `.center` triggers a swap; directional zones trigger insertion.
    static func findDropTarget(forKey draggedKey: WindowSlot) -> DropTarget? {
        guard let screen = NSScreen.main else { return nil }
        let cursor = NSEvent.mouseLocation           // AppKit coords (bottom-left origin)
        let screenHeight = NSScreen.screens[0].frame.height
        // Use precomputed slot-tree frames instead of live AX reads.
        let frames = LayoutService.shared.computeFrames(screen: screen)

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
    private static func pruneOffScreenWindows(screen: NSScreen) {
        let onScreen = onScreenWindowIDs()
        guard !onScreen.isEmpty else { return }
        let leaves = TilingRootStore.shared.leavesInVisibleRoot()
        for leaf in leaves {
            guard case .window(let w) = leaf else { continue }
            guard !onScreen.contains(w.windowHash) else { continue }
            Logger.shared.log("pruning off-screen window: pid=\(w.pid) hash=\(w.windowHash)")
            ResizeObserver.shared.stopObserving(key: w, pid: w.pid)
            TilingSnapService.shared.removeAndReflow(w, screen: screen)
        }
        let scrollingLeaves = ScrollingRootStore.shared.leavesInVisibleScrollingRoot()
        for leaf in scrollingLeaves {
            guard case .window(let w) = leaf else { continue }
            guard !onScreen.contains(w.windowHash) else { continue }
            Logger.shared.log("pruning off-screen scrolling window: pid=\(w.pid) hash=\(w.windowHash)")
            ResizeObserver.shared.stopObserving(key: w, pid: w.pid)
            ScrollingRootStore.shared.removeWindow(w, screen: screen)
        }
    }

    private static func onScreenWindowIDs() -> Set<UInt> {
        OnScreenWindowCache.visibleHashes()
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
