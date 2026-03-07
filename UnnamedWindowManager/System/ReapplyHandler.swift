import AppKit
import ApplicationServices

// Coordinates layout reapplication, drop-target detection, and size clamping.
struct ReapplyHandler {

    /// Reapplies the layout for a single already-tracked window.
    /// No-op if the window is no longer in the slot tree.
    static func reapply(window: AXUIElement, key: WindowSlot) {
        guard SnapService.shared.isTracked(key) else { return }
        guard let screen = NSScreen.main else { return }
        LayoutService.shared.applyLayout(screen: screen)
    }

    /// Reapplies the layout for all snapped windows and refreshes their visibility state.
    /// Marks all windows as reapplying for 200 ms to suppress re-entrant AX notifications.
    static func reapplyAll() {
        guard let screen = NSScreen.main else { return }
        pruneOffScreenWindows(screen: screen)
        let leaves = SnapService.shared.leavesInVisibleRoot()
        let allWindows = Set(leaves.compactMap { leaf -> WindowSlot? in
            if case .window(let w) = leaf { return w }
            return nil
        })
        ResizeObserver.shared.reapplying.formUnion(allWindows)
        LayoutService.shared.applyLayout(screen: screen)
        WindowVisibilityManager.shared.applyVisibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            ResizeObserver.shared.reapplying.subtract(allWindows)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .snapStateChanged, object: nil)
        }
    }

    /// Returns the drop target (window + zone) under the current mouse cursor,
    /// excluding `draggedKey` itself. Returns `nil` when the cursor is not over any
    /// managed window. `.center` triggers a swap; directional zones trigger insertion.
    static func findDropTarget(forKey draggedKey: WindowSlot) -> DropTarget? {
        let cursor = NSEvent.mouseLocation           // AppKit coords (bottom-left origin)
        let screenHeight = NSScreen.screens[0].frame.height
        let leaves = SnapService.shared.leavesInVisibleRoot()
        let elements = ResizeObserver.shared.elements

        for leaf in leaves {
            guard case .window(let w) = leaf, w != draggedKey else { continue }
            guard let axElement = elements[w],
                  let axOrigin = readOrigin(of: axElement),
                  let axSize   = readSize(of: axElement) else { continue }

            // AX coords: top-left origin, y increases downward.
            // AppKit coords: bottom-left origin, y increases upward.
            let appKitY = screenHeight - axOrigin.y - axSize.height
            let frame = CGRect(x: axOrigin.x, y: appKitY, width: axSize.width, height: axSize.height)

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
        let leaves = SnapService.shared.leavesInVisibleRoot()
        for leaf in leaves {
            guard case .window(let w) = leaf else { continue }
            guard !onScreen.contains(w.windowHash) else { continue }
            Logger.shared.log("pruning off-screen window: pid=\(w.pid) hash=\(w.windowHash)")
            ResizeObserver.shared.stopObserving(key: w, pid: w.pid)
            SnapService.shared.removeAndReflow(w, screen: screen)
        }
    }

    private static func onScreenWindowIDs() -> Set<UInt> {
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var ids = Set<UInt>()
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid   = info[kCGWindowOwnerPID as String] as? Int,
                  let wid   = info[kCGWindowNumber as String] as? CGWindowID,
                  pid_t(pid) != ownPID
            else { continue }
            ids.insert(UInt(wid))
        }
        return ids
    }

    /// Returns `size` clamped to the per-screen maximums defined in `Config`.
    static func clampSize(_ size: CGSize, screen: NSScreen) -> CGSize {
        let visible = screen.visibleFrame
        let maxW = visible.width  * Config.maxWidthFraction
        let maxH = visible.height * Config.maxHeightFraction - Config.gap * 2
        return CGSize(
            width:  min(size.width,  maxW),
            height: min(size.height, maxH)
        )
    }
}
