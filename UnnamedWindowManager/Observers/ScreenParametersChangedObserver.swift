import AppKit

// Wraps NSApplication.didChangeScreenParametersNotification as a pub/sub event.
final class ScreenParametersChangedObserver: EventObserver<ScreenParametersChangedEvent> {
    static let shared = ScreenParametersChangedObserver()

    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screenParametersChanged() {
        notify(ScreenParametersChangedEvent())
    }
}
