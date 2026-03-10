import AppKit
import ApplicationServices

// Walks the slot tree and applies window positions and sizes via the Accessibility API.
final class LayoutService {
    static let shared = LayoutService()
    private init() {}

    /// Positions all tiled windows on `screen` by walking the current slot tree.
    /// The root origin is shifted inward by outer gaps; leaf windows are inset by inner gap.
    func applyLayout(screen: NSScreen) {
        let visible       = screen.visibleFrame
        let primaryHeight = NSScreen.screens[0].frame.height
        // y is flipped: AX uses top-left origin, AppKit uses bottom-left.
        let og = Config.outerGaps
        let origin = CGPoint(x: visible.minX + og.left!, y: primaryHeight - visible.maxY + og.top!)
        let elements = ResizeObserver.shared.elements
        guard let root = TileService.shared.snapshotVisibleRoot() else { return }
        applyLayout(root, origin: origin, elements: elements)
    }

    /// Walks the root's direct children in order, advancing the cursor after each child
    /// by the child's width (horizontal root) or height (vertical root).
    private func applyLayout(
        _ root: TilingRootSlot,
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

    /// Recursively positions a slot subtree starting at `origin`.
    /// - Window leaf: applies gap insets, then writes position and size via AX.
    /// - Horizontal container: lays children left-to-right.
    /// - Vertical container: lays children top-to-bottom.
    private func applyLayout(
        _ slot: Slot,
        origin: CGPoint,
        elements: [WindowSlot: AXUIElement]
    ) {
        switch slot {
        case .window(let w):
            guard let ax = elements[w] else { return }
            let g = w.gaps ? Config.innerGap : 0
            var pos  = CGPoint(x: (origin.x + g).rounded(), y: (origin.y + g).rounded())
            var size = CGSize(width: (w.width - g * 2).rounded(), height: (w.height - g * 2).rounded())
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
}
