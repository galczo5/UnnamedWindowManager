import CoreVideo
import CoreFoundation

// Drives frame-accurate scrolling animations via CVDisplayLink.
// Ticks run on the CVDisplayLink render thread — subscribers must handle thread safety.
// Call startIfNeeded() when animations begin and stopIfIdle() when all animations finish.
final class ScrollingDisplayLinkTickObserver: EventObserver<ScrollingDisplayLinkTickEvent> {
    static let shared = ScrollingDisplayLinkTickObserver()
    private var displayLink: CVDisplayLink?

    private override init() {}

    func startIfNeeded() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userInfo -> CVReturn in
            let observer = Unmanaged<ScrollingDisplayLinkTickObserver>.fromOpaque(userInfo!).takeUnretainedValue()
            observer.notify(ScrollingDisplayLinkTickEvent(timestamp: CFAbsoluteTimeGetCurrent()))
            return kCVReturnSuccess
        }, selfPtr)
        CVDisplayLinkStart(link)
        displayLink = link
    }

    func stopIfIdle() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }
}
