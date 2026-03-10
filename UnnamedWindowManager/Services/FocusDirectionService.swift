import AppKit
import ApplicationServices

enum FocusDirection {
    case left, right, up, down
}

private enum Axis { case horizontal, vertical }

// Shared spatial logic for directional window focus: leaf rect computation, nearest-neighbor search, and activation.
struct FocusDirectionService {

    static func focus(_ direction: FocusDirection) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success else { return }
        let axWindow = ref as! AXUIElement
        let currentKey = windowSlot(for: axWindow, pid: pid)

        guard let root = TileService.shared.snapshotVisibleRoot() else { return }
        let rects = leafRects(in: root)
        guard let sourceRect = rects.first(where: { $0.key == currentKey })?.rect else { return }

        guard let targetKey = nearest(from: sourceRect, direction: direction, candidates: rects, exclude: currentKey) else { return }
        activateWindow(targetKey)
    }

    // MARK: - Private

    private struct LeafRect {
        let key: WindowSlot
        let rect: CGRect
    }

    private static func leafRects(in root: TilingRootSlot) -> [LeafRect] {
        guard let screen = NSScreen.main else { return [] }
        let primaryHeight = NSScreen.screens[0].frame.height
        let visible = screen.visibleFrame
        let og = Config.outerGaps
        let origin = CGPoint(x: visible.minX + og.left!, y: primaryHeight - visible.maxY + og.top!)

        var results: [LeafRect] = []
        var cursor = origin
        for child in root.children {
            collectLeafRects(child, origin: cursor, into: &results)
            if root.orientation == .horizontal {
                cursor.x += child.width
            } else {
                cursor.y += child.height
            }
        }
        return results
    }

    private static func collectLeafRects(_ slot: Slot, origin: CGPoint, into results: inout [LeafRect]) {
        switch slot {
        case .window(let w):
            let g = w.gaps ? Config.innerGap : 0
            let rect = CGRect(
                x: (origin.x + g).rounded(),
                y: (origin.y + g).rounded(),
                width: (w.width - g * 2).rounded(),
                height: (w.height - g * 2).rounded()
            )
            results.append(LeafRect(key: w, rect: rect))
        case .horizontal(let h):
            var cursor = origin
            for child in h.children {
                collectLeafRects(child, origin: cursor, into: &results)
                cursor.x += child.width
            }
        case .vertical(let v):
            var cursor = origin
            for child in v.children {
                collectLeafRects(child, origin: cursor, into: &results)
                cursor.y += child.height
            }
        }
    }

    private static func nearest(
        from source: CGRect,
        direction: FocusDirection,
        candidates: [LeafRect],
        exclude: WindowSlot
    ) -> WindowSlot? {
        let sc = CGPoint(x: source.midX, y: source.midY)

        let filtered = candidates.filter { lr in
            guard lr.key != exclude else { return false }
            let cc = CGPoint(x: lr.rect.midX, y: lr.rect.midY)
            switch direction {
            case .left:  return cc.x < sc.x
            case .right: return cc.x > sc.x
            case .up:    return cc.y < sc.y
            case .down:  return cc.y > sc.y
            }
        }

        func overlap(_ r: CGRect, _ s: CGRect, axis: Axis) -> CGFloat {
            switch axis {
            case .horizontal: return max(0, min(r.maxX, s.maxX) - max(r.minX, s.minX))
            case .vertical:   return max(0, min(r.maxY, s.maxY) - max(r.minY, s.minY))
            }
        }

        return filtered.min(by: { a, b in
            let ac = CGPoint(x: a.rect.midX, y: a.rect.midY)
            let bc = CGPoint(x: b.rect.midX, y: b.rect.midY)
            switch direction {
            case .left, .right:
                // Prefer most Y overlap; break ties by X distance.
                let oa = overlap(a.rect, source, axis: .vertical)
                let ob = overlap(b.rect, source, axis: .vertical)
                if oa != ob { return oa > ob }
                return abs(ac.x - sc.x) < abs(bc.x - sc.x)
            case .up, .down:
                // Prefer most X overlap; break ties by Y distance.
                let oa = overlap(a.rect, source, axis: .horizontal)
                let ob = overlap(b.rect, source, axis: .horizontal)
                if oa != ob { return oa > ob }
                return abs(ac.y - sc.y) < abs(bc.y - sc.y)
            }
        })?.key
    }

    private static func activateWindow(_ key: WindowSlot) {
        let elements = ResizeObserver.shared.elements
        guard let axElement = elements[key] else { return }
        guard let app = NSRunningApplication(processIdentifier: key.pid) else { return }
        app.activate()
        AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
    }
}
