// Notifies subscribers when a tracked window is resized (including fullscreen entry).
final class WindowResizedObserver: EventObserver<WindowResizedEvent> {
    static let shared = WindowResizedObserver()
}
