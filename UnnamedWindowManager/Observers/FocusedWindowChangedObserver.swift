import AppKit
import ApplicationServices

// C-compatible callback for kAXFocusedWindowChangedNotification — must not capture Swift context.
private func focusChangedCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let obs = Unmanaged<FocusedWindowChangedObserver>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        obs.notify(FocusedWindowChangedEvent(pid: pid))
    }
}

// Observes AX focus changes across all apps and fires FocusedWindowChangedEvent.
// Also fires on app activation, matching the pre-existing behavior.
final class FocusedWindowChangedObserver: EventObserver<FocusedWindowChangedEvent> {
    static let shared = FocusedWindowChangedObserver()
    private var observerManager: AppObserverManager?

    func start() {
        observerManager = AppObserverManager(
            callback: focusChangedCallback,
            notifications: [
                kAXFocusedWindowChangedNotification as CFString,
                kAXMainWindowChangedNotification    as CFString,
            ],
            refcon: Unmanaged.passUnretained(self).toOpaque())

        AppActivatedObserver.shared.subscribe { [weak self] event in
            let pid = event.app.processIdentifier
            self?.observerManager?.observeApp(pid: pid)
            self?.notify(FocusedWindowChangedEvent(pid: pid))
        }
        AppTerminatedObserver.shared.subscribe { [weak self] event in
            self?.observerManager?.removeAppObserver(pid: event.app.processIdentifier)
        }

        if let app = NSWorkspace.shared.frontmostApplication {
            observerManager?.observeApp(pid: app.processIdentifier)
            notify(FocusedWindowChangedEvent(pid: app.processIdentifier))
        }
    }
}
