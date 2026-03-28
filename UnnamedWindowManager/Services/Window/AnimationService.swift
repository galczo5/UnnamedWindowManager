import ApplicationServices
import Foundation

/// Animates window frames via interpolated AX position/size calls over a configurable duration.
final class AnimationService {
    static let shared = AnimationService()
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
        var timer: DispatchSourceTimer
    }

    private var animations: [UInt: Animation] = [:]

    /// Animates `ax` from its current frame to `(pos, size)`.
    /// Falls through to an immediate AX call when duration is 0 or the current frame can't be read.
    func animate(key: WindowSlot, ax: AXUIElement, to pos: CGPoint, size: CGSize,
                 positionOnly: Bool = false) {
        let duration = Config.animationDuration

        cancel(hash: key.windowHash)

        guard duration > 0,
              let curPos = readOrigin(of: ax),
              let curSize = readSize(of: ax) else {
            applyImmediate(ax: ax, pos: pos, size: size, positionOnly: positionOnly)
            return
        }

        let posDelta = abs(curPos.x - pos.x) + abs(curPos.y - pos.y)
        let sizeDelta = abs(curSize.width - size.width) + abs(curSize.height - size.height)
        if posDelta < 1 && (positionOnly || sizeDelta < 1) { return }

        ResizeObserver.shared.reapplying.insert(key)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let sizeChanged = !positionOnly && sizeDelta >= 1
        let anim = Animation(ax: ax, key: key,
                             startPos: curPos, startSize: curSize,
                             endPos: pos, endSize: size,
                             startTime: CFAbsoluteTimeGetCurrent(),
                             duration: duration, sizeChanged: sizeChanged,
                             timer: timer)
        animations[key.windowHash] = anim

        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            self?.tick(hash: key.windowHash)
        }
        timer.resume()
    }

    func cancel(hash: UInt) {
        guard let anim = animations.removeValue(forKey: hash) else { return }
        anim.timer.cancel()
        ResizeObserver.shared.reapplying.remove(anim.key)
    }

    func cancelAll() {
        let hashes = Array(animations.keys)
        for hash in hashes { cancel(hash: hash) }
    }

    var isAnimating: Bool { !animations.isEmpty }

    // MARK: - Private

    private func tick(hash: UInt) {
        guard let anim = animations[hash] else { return }

        let elapsed = CFAbsoluteTimeGetCurrent() - anim.startTime
        let raw = min(elapsed / anim.duration, 1.0)
        let t = CGFloat(easeOutCubic(raw))

        var pos = CGPoint(
            x: (anim.startPos.x + t * (anim.endPos.x - anim.startPos.x)).rounded(),
            y: (anim.startPos.y + t * (anim.endPos.y - anim.startPos.y)).rounded()
        )
        if let posVal = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(anim.ax, kAXPositionAttribute as CFString, posVal)
        }
        if anim.sizeChanged {
            var size = CGSize(
                width:  (anim.startSize.width  + t * (anim.endSize.width  - anim.startSize.width)).rounded(),
                height: (anim.startSize.height + t * (anim.endSize.height - anim.startSize.height)).rounded()
            )
            if let sizeVal = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(anim.ax, kAXSizeAttribute as CFString, sizeVal)
            }
        }

        if raw >= 1.0 {
            cancel(hash: hash)
        }
    }

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

    private func easeOutCubic(_ t: Double) -> Double {
        let p = t - 1
        return p * p * p + 1
    }
}
