import AppKit
import ApplicationServices

// Applies window positions and sizes for a ScrollingRootSlot via the Accessibility API.
final class ScrollingLayoutService {
    static let shared = ScrollingLayoutService()
    private init() {}

    func applyLayout(root: ScrollingRootSlot, origin: CGPoint,
                     elements: [WindowSlot: AXUIElement],
                     zonesChanged: Bool = true) {
        let centerWidth = (root.width * 0.8).rounded()
        let remaining   = root.width - centerWidth
        let bothSides   = root.left != nil && root.right != nil
        let sideWidth   = (bothSides ? remaining / 2 : remaining).rounded()
        let leftWidth   = root.left != nil ? sideWidth : 0

        if zonesChanged, let left = root.left {
            applySlot(left, origin: CGPoint(x: origin.x, y: origin.y), elements: elements)
        }
        applySlot(root.center,
                  origin: CGPoint(x: origin.x + leftWidth, y: origin.y),
                  elements: elements)
        if zonesChanged, let right = root.right {
            applySlot(right,
                      origin: CGPoint(x: origin.x + leftWidth + centerWidth, y: origin.y),
                      elements: elements)
        }
    }

    private func applySlot(_ slot: Slot, origin: CGPoint, elements: [WindowSlot: AXUIElement]) {
        switch slot {
        case .window(let w):
            guard let ax = elements[w] else { return }
            let g = w.gaps ? Config.innerGap : 0
            var pos  = CGPoint(x: (origin.x + g).rounded(), y: (origin.y + g).rounded())
            var size = CGSize(width: (w.width - g * 2).rounded(), height: (w.height - g * 2).rounded())
            Logger.shared.log("scroll key=\(w.windowHash) origin=(\(Int(pos.x)),\(Int(pos.y))) size=(\(Int(size.width))×\(Int(size.height)))")
            if let posVal  = AXValueCreate(.cgPoint, &pos)  { AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, posVal) }
            if let sizeVal = AXValueCreate(.cgSize,  &size) { AXUIElementSetAttributeValue(ax, kAXSizeAttribute  as CFString, sizeVal) }
        case .stacking(let s):
            for w in s.children {
                guard let ax = elements[w] else { continue }
                let g = w.gaps ? Config.innerGap : 0
                let xOffset: CGFloat = s.align == .left ? 0 : s.width - w.width
                var pos  = CGPoint(x: (origin.x + xOffset + g).rounded(), y: (origin.y + g).rounded())
                var size = CGSize(width: (w.width - g * 2).rounded(), height: (w.height - g * 2).rounded())
                Logger.shared.log("scroll key=\(w.windowHash) origin=(\(Int(pos.x)),\(Int(pos.y))) size=(\(Int(size.width))×\(Int(size.height)))")
                if let posVal  = AXValueCreate(.cgPoint, &pos)  { AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, posVal) }
                if let sizeVal = AXValueCreate(.cgSize,  &size) { AXUIElementSetAttributeValue(ax, kAXSizeAttribute  as CFString, sizeVal) }
            }
        default:
            break
        }
    }
}
