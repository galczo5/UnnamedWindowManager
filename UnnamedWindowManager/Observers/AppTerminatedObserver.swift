import AppKit

// Observes NSWorkspace app termination and notifies subscribers with the terminated app.
final class AppTerminatedObserver: EventObserver<AppTerminatedEvent> {
    static let shared = AppTerminatedObserver()

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didTerminateApp(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func didTerminateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        notify(AppTerminatedEvent(app: app))
    }
}
