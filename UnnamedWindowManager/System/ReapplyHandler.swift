//
//  ReapplyHandler.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

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
        let leaves = SnapService.shared.allLeaves()
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
    }

    /// Returns the tracked window whose screen frame contains the current mouse cursor,
    /// excluding `draggedKey` itself. Used to identify a drop target during a drag.
    static func findSwapTarget(forKey draggedKey: WindowSlot) -> WindowSlot? {
        let cursor = NSEvent.mouseLocation           // AppKit coords (bottom-left origin)
        let screenHeight = NSScreen.screens[0].frame.height
        let leaves = SnapService.shared.allLeaves()
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

            if frame.contains(cursor) { return w }
        }
        return nil
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
