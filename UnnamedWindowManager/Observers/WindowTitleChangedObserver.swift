// Notifies subscribers when a tracked window's title changes.
final class WindowTitleChangedObserver: EventObserver<WindowTitleChangedEvent> {
    static let shared = WindowTitleChangedObserver()
}
