import CoreFoundation

// Event fired on each CVDisplayLink frame tick for scrolling animations.
struct ScrollingDisplayLinkTickEvent: AppEvent {
    let timestamp: CFAbsoluteTime
}
