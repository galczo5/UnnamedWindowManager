import CoreVideo
import CoreFoundation

// Drives frame-accurate tiling animations via CVDisplayLink.
// Ticks run on the CVDisplayLink render thread — subscribers must handle thread safety.
// Call startIfNeeded() when animations begin and stopIfIdle() when all animations finish.
final class DisplayLinkTickObserver: EventObserver<DisplayLinkTickEvent> {
    static let shared = DisplayLinkTickObserver()
    private var displayLink: CVDisplayLink?

    private override init() {}

    func startIfNeeded() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userInfo -> CVReturn in
            let observer = Unmanaged<DisplayLinkTickObserver>.fromOpaque(userInfo!).takeUnretainedValue()
            observer.notify(DisplayLinkTickEvent(timestamp: CFAbsoluteTimeGetCurrent()))
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
