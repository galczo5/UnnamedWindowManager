import AppKit

// Observes NSWorkspace app activation and notifies subscribers with the activated app.
final class AppActivatedObserver: EventObserver<AppActivatedEvent> {
    static let shared = AppActivatedObserver()

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didActivateApp(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func didActivateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        notify(AppActivatedEvent(app: app))
    }
}
