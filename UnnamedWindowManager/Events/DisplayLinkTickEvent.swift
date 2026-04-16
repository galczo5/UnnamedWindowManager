import CoreFoundation

// Event fired on each CVDisplayLink frame tick for tiling animations.
struct DisplayLinkTickEvent: AppEvent {
    let timestamp: CFAbsoluteTime
}
