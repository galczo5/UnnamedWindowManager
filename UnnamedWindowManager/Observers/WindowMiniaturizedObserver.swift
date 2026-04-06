// Notifies subscribers when a tracked window is miniaturized.
final class WindowMiniaturizedObserver: EventObserver<WindowMiniaturizedEvent> {
    static let shared = WindowMiniaturizedObserver()
}
