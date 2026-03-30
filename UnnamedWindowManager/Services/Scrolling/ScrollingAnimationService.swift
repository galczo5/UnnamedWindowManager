import ApplicationServices
import CoreVideo
import Foundation

/// Direction-aware window animator for scrolling roots.
/// Uses logical before-layout positions as start points to prevent jump artefacts on rapid scrolling.
final class ScrollingAnimationService {
    static let shared = ScrollingAnimationService()
    private init() {}

    private struct Animation {
        let ax: AXUIElement
        let key: WindowSlot
        let startPos: CGPoint
        let startSize: CGSize
        let endPos: CGPoint
        let endSize: CGSize
        let startTime: CFAbsoluteTime
        let duration: CFTimeInterval
        let sizeChanged: Bool
    }

    private var animations: [UInt: Animation] = [:]
    private var displayLink: CVDisplayLink?

    var isAnimating: Bool { !animations.isEmpty }

    /// Entry point for scrollLeft / scrollRight. Uses before-state positions as animation starts
    /// so rapid scrolling never produces jumps or direction reversals.
    func animateScroll(before: ScrollingRootSlot,
                       after: ScrollingRootSlot,
                       origin: CGPoint,
                       elements: [WindowSlot: AXUIElement]) {
        let duration = Config.animationDuration
        let beforePos = computePositions(root: before, origin: origin)
        let afterPos  = computePositions(root: after,  origin: origin)

        let transitioning = transitioningHashes(before: before, after: after)

        let keysByHash = Dictionary(uniqueKeysWithValues: elements.map { ($0.key.windowHash, $0) })

        for (hash, end) in afterPos {
            guard let (key, ax) = keysByHash[hash] else { continue }
            let start = beforePos[hash] ?? end

            let posDelta  = abs(start.pos.x - end.pos.x)  + abs(start.pos.y - end.pos.y)
            let sizeDelta = abs(start.size.width - end.size.width) + abs(start.size.height - end.size.height)
            guard posDelta >= 1 || sizeDelta >= 1 else { continue }

            if duration > 0 && transitioning.contains(hash) {
                cancel(hash: hash)
                ResizeObserver.shared.reapplying.insert(key)
                animations[hash] = Animation(
                    ax: ax, key: key,
                    startPos: start.pos, startSize: start.size,
                    endPos: end.pos,     endSize: end.size,
                    startTime: CFAbsoluteTimeGetCurrent(),
                    duration: duration,
                    sizeChanged: sizeDelta >= 1
                )
            } else {
                cancel(hash: hash)
                applyImmediate(ax: ax, pos: end.pos, size: end.size, positionOnly: false)
            }
        }
        startDisplayLinkIfNeeded()
    }

    /// Used by ScrollingLayoutService for non-scroll repositioning (resize, scrollToCenter).
    /// Reads current AX position as start — same behaviour as AnimationService.animate.
    func animate(key: WindowSlot, ax: AXUIElement, to pos: CGPoint, size: CGSize,
                 positionOnly: Bool = false) {
        let duration = Config.animationDuration
        cancel(hash: key.windowHash)

        guard duration > 0,
              let curPos  = readOrigin(of: ax),
              let curSize = readSize(of: ax) else {
            applyImmediate(ax: ax, pos: pos, size: size, positionOnly: positionOnly)
            return
        }

        let posDelta  = abs(curPos.x - pos.x) + abs(curPos.y - pos.y)
        let sizeDelta = abs(curSize.width - size.width) + abs(curSize.height - size.height)
        if posDelta < 1 && (positionOnly || sizeDelta < 1) { return }

        ResizeObserver.shared.reapplying.insert(key)
        animations[key.windowHash] = Animation(
            ax: ax, key: key,
            startPos: curPos, startSize: curSize,
            endPos: pos, endSize: size,
            startTime: CFAbsoluteTimeGetCurrent(),
            duration: duration,
            sizeChanged: !positionOnly && sizeDelta >= 1
        )
        startDisplayLinkIfNeeded()
    }

    func cancel(hash: UInt) {
        guard let anim = animations.removeValue(forKey: hash) else { return }
        ResizeObserver.shared.reapplying.remove(anim.key)
        stopDisplayLinkIfIdle()
    }

    func cancelAll() {
        let hashes = Array(animations.keys)
        for hash in hashes { cancel(hash: hash) }
    }

    // MARK: - Position computation

    private func computePositions(root: ScrollingRootSlot,
                                   origin: CGPoint) -> [UInt: (pos: CGPoint, size: CGSize)] {
        var result: [UInt: (pos: CGPoint, size: CGSize)] = [:]
        let leftWidth   = root.left?.size.width ?? 0
        let centerWidth = root.center.size.width

        if let left = root.left {
            collectPositions(left, origin: CGPoint(x: origin.x, y: origin.y), into: &result)
        }
        collectPositions(root.center,
                         origin: CGPoint(x: origin.x + leftWidth, y: origin.y),
                         into: &result)
        if let right = root.right {
            collectPositions(right,
                             origin: CGPoint(x: origin.x + leftWidth + centerWidth, y: origin.y),
                             into: &result)
        }
        return result
    }

    private func collectPositions(_ slot: Slot, origin: CGPoint,
                                   into result: inout [UInt: (pos: CGPoint, size: CGSize)]) {
        switch slot {
        case .window(let w):
            let g = w.gaps ? Config.innerGap : 0
            let pos  = CGPoint(x: (origin.x + g).rounded(), y: (origin.y + g).rounded())
            let size = CGSize(width: (w.size.width - g * 2).rounded(),
                              height: (w.size.height - g * 2).rounded())
            result[w.windowHash] = (pos, size)
        case .stacking(let s):
            for w in s.children {
                let g = w.gaps ? Config.innerGap : 0
                let xOffset: CGFloat = s.align == .left ? 0 : s.size.width - w.size.width
                let pos  = CGPoint(x: (origin.x + xOffset + g).rounded(), y: (origin.y + g).rounded())
                let size = CGSize(width: (w.size.width - g * 2).rounded(),
                                  height: (w.size.height - g * 2).rounded())
                result[w.windowHash] = (pos, size)
            }
        default: break
        }
    }

    private func transitioningHashes(before: ScrollingRootSlot,
                                      after: ScrollingRootSlot) -> Set<UInt> {
        let beforeCenter = slotHashes(before.center)
        let afterCenter  = slotHashes(after.center)
        return beforeCenter.symmetricDifference(afterCenter)
    }

    private func slotHashes(_ slot: Slot) -> Set<UInt> {
        switch slot {
        case .window(let w):   return [w.windowHash]
        case .stacking(let s): return Set(s.children.map(\.windowHash))
        default:               return []
        }
    }

    // MARK: - Display Link

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userInfo -> CVReturn in
            let service = Unmanaged<ScrollingAnimationService>.fromOpaque(userInfo!).takeUnretainedValue()
            DispatchQueue.main.async { service.tickAll() }
            return kCVReturnSuccess
        }, selfPtr)
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stopDisplayLinkIfIdle() {
        guard animations.isEmpty, let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    // MARK: - Tick

    private func tickAll() {
        let now = CFAbsoluteTimeGetCurrent()
        var finished: [UInt] = []

        for (hash, anim) in animations {
            let elapsed = now - anim.startTime
            let raw = min(elapsed / anim.duration, 1.0)
            let done = raw >= 1.0
            let t = CGFloat(done ? 1.0 : easeOutQuart(raw))

            var pos = CGPoint(
                x: anim.startPos.x + t * (anim.endPos.x - anim.startPos.x),
                y: anim.startPos.y + t * (anim.endPos.y - anim.startPos.y)
            )
            if done {
                pos.x.round()
                pos.y.round()
            }
            if let posVal = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(anim.ax, kAXPositionAttribute as CFString, posVal)
            }

            if anim.sizeChanged {
                var size = CGSize(
                    width:  anim.startSize.width  + t * (anim.endSize.width  - anim.startSize.width),
                    height: anim.startSize.height + t * (anim.endSize.height - anim.startSize.height)
                )
                if done {
                    size.width.round()
                    size.height.round()
                }
                if let sizeVal = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(anim.ax, kAXSizeAttribute as CFString, sizeVal)
                }
            }

            if done { finished.append(hash) }
        }

        for hash in finished { cancel(hash: hash) }
    }

    // MARK: - Helpers

    private func applyImmediate(ax: AXUIElement, pos: CGPoint, size: CGSize, positionOnly: Bool) {
        var p = pos
        if let posVal = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, posVal)
        }
        if !positionOnly {
            var s = size
            if let sizeVal = AXValueCreate(.cgSize, &s) {
                AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, sizeVal)
            }
        }
    }

    private func easeOutQuart(_ t: Double) -> Double {
        let p = t - 1
        return -(p * p * p * p - 1)
    }
}
