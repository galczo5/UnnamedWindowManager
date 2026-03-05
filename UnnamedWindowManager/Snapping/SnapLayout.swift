//
//  SnapLayout.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

extension WindowSnapper {

    // MARK: - Tree layout

    /// Positions all snapped windows by walking the slot tree from the root.
    static func applyLayout(screen: NSScreen) {
        let visible       = screen.visibleFrame
        let primaryHeight = NSScreen.screens[0].frame.height
        // Shift the root origin inward by one gap so the outer gap equals the inner gap (2×Config.gap).
        let origin = CGPoint(x: visible.minX + Config.gap, y: primaryHeight - visible.maxY + Config.gap)
        let elements = ResizeObserver.shared.elements
        let root = ManagedSlotRegistry.shared.snapshotRoot()
        applyLayout(root, origin: origin, elements: elements)
    }

    private static func applyLayout(
        _ root: RootSlot,
        origin: CGPoint,
        elements: [WindowSlot: AXUIElement]
    ) {
        var cursor = origin
        for child in root.children {
            applyLayout(child, origin: cursor, elements: elements)
            if root.orientation == .horizontal {
                cursor.x += child.width
            } else {
                cursor.y += child.height
            }
        }
    }

    private static func applyLayout(
        _ slot: Slot,
        origin: CGPoint,
        elements: [WindowSlot: AXUIElement]
    ) {
        switch slot {
        case .window(let w):
            guard let ax = elements[w] else { return }
            let g = w.gaps ? Config.gap : 0
            var pos  = CGPoint(x: origin.x + g, y: origin.y + g)
            var size = CGSize(width: w.width - g * 2, height: w.height - g * 2)
            Logger.shared.log("key=\(w.windowHash) origin=(\(Int(pos.x)),\(Int(pos.y))) size=(\(Int(size.width))×\(Int(size.height)))")
            if let posVal = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, posVal)
            }
            if let sizeVal = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, sizeVal)
            }
        case .horizontal(let h):
            var cursor = origin
            for child in h.children {
                applyLayout(child, origin: cursor, elements: elements)
                cursor.x += child.width
            }
        case .vertical(let v):
            var cursor = origin
            for child in v.children {
                applyLayout(child, origin: cursor, elements: elements)
                cursor.y += child.height
            }
        }
    }

    // MARK: - Swap target (center drop zone)

    /// Returns the tracked window under the cursor, excluding the dragged window itself.
    static func findSwapTarget(forKey draggedKey: WindowSlot) -> WindowSlot? {
        let cursor = NSEvent.mouseLocation           // AppKit coords (bottom-left origin)
        let screenHeight = NSScreen.screens[0].frame.height
        let leaves = ManagedSlotRegistry.shared.allLeaves()
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

    // MARK: - Size helpers

    /// Returns `size` with width and height clamped to the per-screen maximums defined in `Config`.
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
