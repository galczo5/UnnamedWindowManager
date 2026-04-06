// Notifies subscribers when a tracked window is destroyed.
final class WindowDestroyedObserver: EventObserver<WindowDestroyedEvent> {
    static let shared = WindowDestroyedObserver()
}
