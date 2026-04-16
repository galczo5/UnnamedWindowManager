import AppKit

// Event fired when an NSWindow's occlusion state changes.
struct WindowOcclusionChangedEvent: AppEvent {
    let window: NSWindow
    let isVisible: Bool
}
