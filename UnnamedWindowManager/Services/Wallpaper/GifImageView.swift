import AppKit
import ImageIO
import QuartzCore

// NSView that pre-decodes GIF frames and animates via CAKeyframeAnimation.
// For single-frame images (PNG/JPG), displays the image statically with no overhead.
final class GifImageView: NSView {
    private var frames: [CGImage] = []
    private var gifAnimation: CAKeyframeAnimation?
    private var occlusionSubscriptionId: UUID?
    private(set) var loadedURL: URL?

    var scaling: String = "fill" {
        didSet { updateGravity() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let id = occlusionSubscriptionId {
            WindowOcclusionChangedObserver.shared.unsubscribe(id: id)
        }
        if let win = window {
            WindowOcclusionChangedObserver.shared.stopObserving(window: win)
        }
    }

    func load(url: URL) {
        if url == loadedURL { return }
        stop()

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        let count = CGImageSourceGetCount(source)
        let decodeOpts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary

        var images: [CGImage] = []
        var delays: [TimeInterval] = []
        for i in 0..<count {
            guard let img = CGImageSourceCreateImageAtIndex(source, i, decodeOpts) else { continue }
            images.append(img)
            delays.append(frameDelay(source: source, index: i))
        }

        frames = images
        loadedURL = url
        updateGravity()

        if frames.count == 1 {
            layer?.contents = frames[0]
        } else if frames.count > 1 {
            buildAnimation(delays: delays)
            resumeAnimation()
            observeOcclusion()
        }
    }

    func stop() {
        layer?.removeAnimation(forKey: "gif")
        gifAnimation = nil
        frames = []
        loadedURL = nil
        if let id = occlusionSubscriptionId {
            WindowOcclusionChangedObserver.shared.unsubscribe(id: id)
            occlusionSubscriptionId = nil
        }
        if let win = window {
            WindowOcclusionChangedObserver.shared.stopObserving(window: win)
        }
    }

    // MARK: - Animation

    private func buildAnimation(delays: [TimeInterval]) {
        let total = delays.reduce(0, +)
        guard total > 0 else { return }

        var cumulative: TimeInterval = 0
        var keyTimes: [NSNumber] = []
        for d in delays {
            keyTimes.append(NSNumber(value: cumulative / total))
            cumulative += d
        }

        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.values = frames
        anim.keyTimes = keyTimes
        anim.duration = total
        anim.repeatCount = .infinity
        anim.calculationMode = .discrete
        anim.isRemovedOnCompletion = false
        gifAnimation = anim
    }

    private func resumeAnimation() {
        guard let anim = gifAnimation else { return }
        layer?.removeAnimation(forKey: "gif")
        layer?.add(anim, forKey: "gif")
    }

    private func pauseAnimation() {
        layer?.removeAnimation(forKey: "gif")
        if let first = frames.first { layer?.contents = first }
    }

    // MARK: - Occlusion

    private func observeOcclusion() {
        guard occlusionSubscriptionId == nil, let win = window else { return }
        occlusionSubscriptionId = WindowOcclusionChangedObserver.shared.subscribe(window: win) { [weak self] event in
            guard let self, event.window === self.window, gifAnimation != nil else { return }
            if event.isVisible {
                resumeAnimation()
            } else {
                pauseAnimation()
            }
        }
    }

    // MARK: - Helpers

    private func frameDelay(source: CGImageSource, index: Int) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifDict = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        if let unclamped = gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped >= 0.02 {
            return unclamped
        }
        if let delay = gifDict[kCGImagePropertyGIFDelayTime] as? Double, delay >= 0.02 {
            return delay
        }
        return 0.1
    }

    private func updateGravity() {
        switch scaling {
        case "fit":     layer?.contentsGravity = .resizeAspect
        case "stretch": layer?.contentsGravity = .resize
        case "center":  layer?.contentsGravity = .center
        default:        layer?.contentsGravity = .resizeAspectFill
        }
    }
}
