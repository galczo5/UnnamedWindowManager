// Pure pub/sub relay for window focus changes. FocusObserver calls notify() directly.
final class WindowFocusChangedObserver: EventObserver<WindowFocusChangedEvent> {
    static let shared = WindowFocusChangedObserver()
}
