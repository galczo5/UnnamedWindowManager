import AppKit
import ApplicationServices

// Walks the slot tree and applies window positions and sizes via the Accessibility API.
final class LayoutService {
    static let shared = LayoutService()
    private init() {}

    private var lastApplied: [UInt: (pos: CGPoint, size: CGSize)] = [:]

    func clearCache() { lastApplied.removeAll() }
    func clearCache(for key: WindowSlot) { lastApplied.removeValue(forKey: key.windowHash) }

    /// Positions all tiled windows on `screen` by walking the current slot tree.
    /// The root origin is shifted inward by outer gaps; leaf windows are inset by inner gap.
    func applyLayout(screen: NSScreen, zonesChanged: Bool = true, scrollingSidesPositionOnly: Bool = false) {
        let visible       = screen.visibleFrame
        let primaryHeight = NSScreen.screens[0].frame.height
        // y is flipped: AX uses top-left origin, AppKit uses bottom-left.
        let og = Config.outerGaps
        let origin = CGPoint(x: visible.minX + og.left!, y: primaryHeight - visible.maxY + og.top!)
        let elements = ResizeObserver.shared.elements
        if let root = TilingRootStore.shared.snapshotVisibleRoot() {
            applyLayout(root, origin: origin, elements: elements)
        }
        if let root = ScrollingTileService.shared.snapshotVisibleScrollingRoot() {
            ScrollingLayoutService.shared.applyLayout(root: root, origin: origin, elements: elements,
                                                      zonesChanged: zonesChanged,
                                                      sidesPositionOnly: scrollingSidesPositionOnly)
        }
    }

    /// Returns precomputed frames (in AX coordinates, top-left origin) for all tiling leaf windows.
    /// Used by drop-target detection to avoid live AX reads.
    func computeFrames(screen: NSScreen) -> [WindowSlot: CGRect] {
        let visible       = screen.visibleFrame
        let primaryHeight = NSScreen.screens[0].frame.height
        let og = Config.outerGaps
        let origin = CGPoint(x: visible.minX + og.left!, y: primaryHeight - visible.maxY + og.top!)
        var frames: [WindowSlot: CGRect] = [:]
        if let root = TilingRootStore.shared.snapshotVisibleRoot() {
            collectFrames(root, origin: origin, into: &frames)
        }
        return frames
    }

    private func collectFrames(_ root: TilingRootSlot, origin: CGPoint, into frames: inout [WindowSlot: CGRect]) {
        var cursor = origin
        for child in root.children {
            collectFrames(child, origin: cursor, into: &frames)
            if root.orientation == .horizontal {
                cursor.x += child.size.width
            } else {
                cursor.y += child.size.height
            }
        }
    }

    private func collectFrames(_ slot: Slot, origin: CGPoint, into frames: inout [WindowSlot: CGRect]) {
        switch slot {
        case .window(let w):
            let g = w.gaps ? Config.innerGap : 0
            let pos  = CGPoint(x: (origin.x + g).rounded(), y: (origin.y + g).rounded())
            let size = CGSize(width: (w.size.width - g * 2).rounded(), height: (w.size.height - g * 2).rounded())
            frames[w] = CGRect(origin: pos, size: size)
        case .split(let s):
            var cursor = origin
            for child in s.children {
                collectFrames(child, origin: cursor, into: &frames)
                if s.orientation == .horizontal {
                    cursor.x += child.size.width
                } else {
                    cursor.y += child.size.height
                }
            }
        case .stacking:
            break
        }
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
                cursor.x += child.size.width
            } else {
                cursor.y += child.size.height
            }
        }
    }

    /// Recursively positions a slot subtree starting at `origin`.
    /// - Window leaf: applies gap insets, then writes position and size via AX.
    /// - Split container: lays children along its orientation axis.
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
            var size = CGSize(width: (w.size.width - g * 2).rounded(), height: (w.size.height - g * 2).rounded())
            if let last = lastApplied[w.windowHash],
               abs(last.pos.x - pos.x) < 1, abs(last.pos.y - pos.y) < 1,
               abs(last.size.width - size.width) < 1, abs(last.size.height - size.height) < 1 {
                return
            }
            lastApplied[w.windowHash] = (pos, size)
            if let posVal = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, posVal)
            }
            if let sizeVal = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, sizeVal)
            }
        case .split(let s):
            var cursor = origin
            for child in s.children {
                applyLayout(child, origin: cursor, elements: elements)
                if s.orientation == .horizontal {
                    cursor.x += child.size.width
                } else {
                    cursor.y += child.size.height
                }
            }
        case .stacking:
            fatalError("StackingSlot encountered in tiling layout — stacking slots are only supported in scrolling roots")
        }
    }
}
