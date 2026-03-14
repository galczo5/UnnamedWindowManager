import AppKit
import ApplicationServices

// Applies window positions and sizes for a ScrollingRootSlot via the Accessibility API.
final class ScrollingLayoutService {
    static let shared = ScrollingLayoutService()
    private init() {}

    private var lastApplied: [UInt: (pos: CGPoint, size: CGSize)] = [:]

    func clearCache() { lastApplied.removeAll() }
    func clearCache(for key: WindowSlot) { lastApplied.removeValue(forKey: key.windowHash) }

    func applyLayout(root: ScrollingRootSlot, origin: CGPoint,
                     elements: [WindowSlot: AXUIElement],
                     zonesChanged: Bool = true,
                     applySides: Bool = true,
                     applyCenter: Bool = true,
                     sidesPositionOnly: Bool = false) {
        let fraction    = root.centerWidthFraction ?? 0.8
        let centerWidth = (root.width * fraction).rounded()
        let remaining   = root.width - centerWidth
        let bothSides   = root.left != nil && root.right != nil
        let sideWidth   = (bothSides ? remaining / 2 : remaining).rounded()
        let leftWidth   = root.left != nil ? sideWidth : 0

        if applySides, zonesChanged, let left = root.left {
            applySlot(left, origin: CGPoint(x: origin.x, y: origin.y), elements: elements,
                      positionOnly: sidesPositionOnly)
        }
        if applyCenter {
            applySlot(root.center,
                      origin: CGPoint(x: origin.x + leftWidth, y: origin.y),
                      elements: elements)
        }
        if applySides, zonesChanged, let right = root.right {
            applySlot(right,
                      origin: CGPoint(x: origin.x + leftWidth + centerWidth, y: origin.y),
                      elements: elements,
                      positionOnly: sidesPositionOnly)
        }
    }

    private func applySlot(_ slot: Slot, origin: CGPoint, elements: [WindowSlot: AXUIElement],
                            positionOnly: Bool = false) {
        switch slot {
        case .window(let w):
            guard let ax = elements[w] else { return }
            let g = w.gaps ? Config.innerGap : 0
            var pos  = CGPoint(x: (origin.x + g).rounded(), y: (origin.y + g).rounded())
            var size = CGSize(width: (w.width - g * 2).rounded(), height: (w.height - g * 2).rounded())
            if positionOnly {
                if let last = lastApplied[w.windowHash],
                   abs(last.pos.x - pos.x) < 1, abs(last.pos.y - pos.y) < 1 { return }
                lastApplied[w.windowHash] = (pos, lastApplied[w.windowHash]?.size ?? size)
                if let posVal = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, posVal) }
            } else {
                if let last = lastApplied[w.windowHash],
                   abs(last.pos.x - pos.x) < 1, abs(last.pos.y - pos.y) < 1,
                   abs(last.size.width - size.width) < 1, abs(last.size.height - size.height) < 1 { return }
                lastApplied[w.windowHash] = (pos, size)
                if let posVal  = AXValueCreate(.cgPoint, &pos)  { AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, posVal) }
                if let sizeVal = AXValueCreate(.cgSize,  &size) { AXUIElementSetAttributeValue(ax, kAXSizeAttribute  as CFString, sizeVal) }
            }
        case .stacking(let s):
            for w in s.children {
                guard let ax = elements[w] else { continue }
                let g = w.gaps ? Config.innerGap : 0
                let xOffset: CGFloat = s.align == .left ? 0 : s.width - w.width
                var pos  = CGPoint(x: (origin.x + xOffset + g).rounded(), y: (origin.y + g).rounded())
                var size = CGSize(width: (w.width - g * 2).rounded(), height: (w.height - g * 2).rounded())
                if positionOnly {
                    if let last = lastApplied[w.windowHash],
                       abs(last.pos.x - pos.x) < 1, abs(last.pos.y - pos.y) < 1 { continue }
                    lastApplied[w.windowHash] = (pos, lastApplied[w.windowHash]?.size ?? size)
                    if let posVal = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, posVal) }
                } else {
                    if let last = lastApplied[w.windowHash],
                       abs(last.pos.x - pos.x) < 1, abs(last.pos.y - pos.y) < 1,
                       abs(last.size.width - size.width) < 1, abs(last.size.height - size.height) < 1 { continue }
                    lastApplied[w.windowHash] = (pos, size)
                    if let posVal  = AXValueCreate(.cgPoint, &pos)  { AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, posVal) }
                    if let sizeVal = AXValueCreate(.cgSize,  &size) { AXUIElementSetAttributeValue(ax, kAXSizeAttribute  as CFString, sizeVal) }
                }
            }
        default:
            break
        }
    }
}
