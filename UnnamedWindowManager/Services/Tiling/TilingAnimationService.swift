import ApplicationServices
import CoreFoundation
import Foundation
import os

/// Animates window frames via interpolated AX position/size calls synced to the display refresh rate.
/// Ticks run directly on the CVDisplayLink render thread for frame-accurate timing.
final class TilingAnimationService {
    static let shared = TilingAnimationService()

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
    private let lock = OSAllocatedUnfairLock()

    /// Keys whose reapplying removal is deferred until all animations finish.
    private var pendingReapplyRemoval = Set<WindowSlot>()

    /// Hashes that have already been animated once; subsequent calls skip animation.
    private var animatedOnce = Set<UInt>()
    private var clearAnimatedOnceWork: DispatchWorkItem?

    private init() {
        DisplayLinkTickObserver.shared.subscribe("TilingAnimationService:init") { [weak self] _ in
            self?.tickAll()
        }
    }

    /// Animates `ax` from its current frame to `(pos, size)`.
    /// Falls through to an immediate AX call when duration is 0 or the current frame can't be read.
    func animate(key: WindowSlot, ax: AXUIElement, to pos: CGPoint, size: CGSize,
                 positionOnly: Bool = false) {
        let duration = Config.animationDuration
        let hash = key.windowHash

        cancel(hash: hash)

        if key.isBeingAnimated || animatedOnce.contains(hash) {
            applyImmediate(ax: ax, pos: pos, size: size, positionOnly: positionOnly)
            return
        }

        guard duration > 0,
              let curPos = readOrigin(of: ax),
              let curSize = readSize(of: ax) else {
            applyImmediate(ax: ax, pos: pos, size: size, positionOnly: positionOnly)
            return
        }

        let posDelta = abs(curPos.x - pos.x) + abs(curPos.y - pos.y)
        let sizeDelta = abs(curSize.width - size.width) + abs(curSize.height - size.height)
        if posDelta < 1 && (positionOnly || sizeDelta < 1) { return }

        markAnimatedOnce(hash)
        WindowTracker.shared.reapplying.insert(key)

        let sizeChanged = !positionOnly && sizeDelta >= 1
        let anim = Animation(ax: ax, key: key,
                             startPos: curPos, startSize: curSize,
                             endPos: pos, endSize: size,
                             startTime: CFAbsoluteTimeGetCurrent(),
                             duration: duration, sizeChanged: sizeChanged)
        lock.withLock { animations[hash] = anim }
        FocusedWindowBorderService.shared.hideForAnimation()
        DisplayLinkTickObserver.shared.startIfNeeded()
    }

    func cancel(hash: UInt) {
        let anim: Animation? = lock.withLock { animations.removeValue(forKey: hash) }
        guard let anim else { return }
        WindowTracker.shared.reapplying.remove(anim.key)
        let empty = lock.withLock { animations.isEmpty }
        if empty { DisplayLinkTickObserver.shared.stopIfIdle() }
    }

    func cancelAll() {
        let all: [UInt: Animation] = lock.withLock {
            let copy = animations
            animations.removeAll()
            return copy
        }
        for anim in all.values {
            WindowTracker.shared.reapplying.remove(anim.key)
        }
        animatedOnce.removeAll()
        clearAnimatedOnceWork?.cancel()
        clearAnimatedOnceWork = nil
        DisplayLinkTickObserver.shared.stopIfIdle()
    }

    var isAnimating: Bool {
        lock.withLock { !animations.isEmpty }
    }

    // MARK: - Tick (runs on CVDisplayLink render thread)

    private func tickAll() {
        let now = CFAbsoluteTimeGetCurrent()
        let snapshot: [UInt: Animation] = lock.withLock { animations }
        var finished: [UInt] = []

        for (hash, anim) in snapshot {
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

        if !finished.isEmpty {
            for hash in finished {
                if let anim = snapshot[hash] {
                    pendingReapplyRemoval.insert(anim.key)
                }
            }
            let allDone: Bool = lock.withLock {
                for hash in finished {
                    if let current = animations[hash],
                       current.startTime == snapshot[hash]!.startTime {
                        animations.removeValue(forKey: hash)
                    }
                }
                return animations.isEmpty
            }
            if allDone {
                DisplayLinkTickObserver.shared.stopIfIdle()
                let pending = pendingReapplyRemoval
                pendingReapplyRemoval.removeAll()
                DispatchQueue.main.async {
                    WindowTracker.shared.reapplying.subtract(pending)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Config.borderRestoreDelay) {
                        FocusedWindowBorderService.shared.recheckActive()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func markAnimatedOnce(_ hash: UInt) {
        animatedOnce.insert(hash)
        clearAnimatedOnceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.animatedOnce.removeAll() }
        clearAnimatedOnceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.animatedOnceTTL, execute: work)
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

    private func easeOutQuart(_ t: Double) -> Double {
        let p = t - 1
        return -(p * p * p * p - 1)
    }
}
