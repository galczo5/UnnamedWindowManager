import AppKit
import ApplicationServices

// Applies window positions and sizes for a ScrollingRootSlot via the Accessibility API.
final class ScrollingLayoutService {
    static let shared = ScrollingLayoutService()
    private init() {}

    private var lastApplied: [UInt: (pos: CGPoint, size: CGSize)] = [:]

    func clearCache() { lastApplied.removeAll() }
    func clearCache(for key: WindowSlot) { lastApplied.removeValue(forKey: key.windowHash) }
    func expectedAXFrame(for windowHash: UInt) -> (pos: CGPoint, size: CGSize)? { lastApplied[windowHash] }
    func updateExpectedFrames(_ frames: [UInt: (pos: CGPoint, size: CGSize)]) {
        for (hash, frame) in frames { lastApplied[hash] = frame }
    }

    func applyLayout(root: ScrollingRootSlot, origin: CGPoint,
                     elements: [WindowSlot: AXUIElement],
                     zonesChanged: Bool = true,
                     applySides: Bool = true,
                     applyCenter: Bool = true,
                     sidesPositionOnly: Bool = false) {
        let leftWidth   = root.left?.size.width ?? 0
        let centerWidth = root.center.size.width

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
            let pos  = CGPoint(x: (origin.x + g).rounded(), y: (origin.y + g).rounded())
            let size = CGSize(width: (w.size.width - g * 2).rounded(), height: (w.size.height - g * 2).rounded())
            if positionOnly {
                if let last = lastApplied[w.windowHash],
                   abs(last.pos.x - pos.x) < 1, abs(last.pos.y - pos.y) < 1 { return }
                lastApplied[w.windowHash] = (pos, lastApplied[w.windowHash]?.size ?? size)
            } else {
                if let last = lastApplied[w.windowHash],
                   abs(last.pos.x - pos.x) < 1, abs(last.pos.y - pos.y) < 1,
                   abs(last.size.width - size.width) < 1, abs(last.size.height - size.height) < 1 { return }
                lastApplied[w.windowHash] = (pos, size)
            }
            ScrollingAnimationService.shared.animate(key: w, ax: ax, to: pos, size: size, positionOnly: positionOnly)
        case .stacking(let s):
            for w in s.children {
                guard let ax = elements[w] else { continue }
                let g = w.gaps ? Config.innerGap : 0
                let xOffset: CGFloat = s.align == .left ? 0 : s.size.width - w.size.width
                let pos  = CGPoint(x: (origin.x + xOffset + g).rounded(), y: (origin.y + g).rounded())
                let size = CGSize(width: (w.size.width - g * 2).rounded(), height: (w.size.height - g * 2).rounded())
                if positionOnly {
                    if let last = lastApplied[w.windowHash],
                       abs(last.pos.x - pos.x) < 1, abs(last.pos.y - pos.y) < 1 { continue }
                    lastApplied[w.windowHash] = (pos, lastApplied[w.windowHash]?.size ?? size)
                } else {
                    if let last = lastApplied[w.windowHash],
                       abs(last.pos.x - pos.x) < 1, abs(last.pos.y - pos.y) < 1,
                       abs(last.size.width - size.width) < 1, abs(last.size.height - size.height) < 1 { continue }
                    lastApplied[w.windowHash] = (pos, size)
                }
                ScrollingAnimationService.shared.animate(key: w, ax: ax, to: pos, size: size, positionOnly: positionOnly)
            }
        default:
            break
        }
    }
}
