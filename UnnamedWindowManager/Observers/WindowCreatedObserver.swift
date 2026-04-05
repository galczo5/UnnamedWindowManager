import AppKit
import ApplicationServices

// C-compatible callback for kAXWindowCreatedNotification — must not capture Swift context.
private func windowCreatedCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "unknown"
    var titleRef: CFTypeRef?
    let title = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success
        ? (titleRef as? String ?? "") : ""
    let wid = windowID(of: element).map(UInt.init)
    let obs = Unmanaged<WindowCreatedObserver>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        obs.notify(WindowCreatedEvent(window: element, pid: pid, appName: appName,
                                      title: title, windowHash: wid))
    }
}

// Observes kAXWindowCreatedNotification for every active app and fires WindowCreatedEvent.
final class WindowCreatedObserver: EventObserver<WindowCreatedEvent> {
    static let shared = WindowCreatedObserver()
    private var observerManager: AppObserverManager?

    func start() {
        observerManager = AppObserverManager(
            callback: windowCreatedCallback,
            notifications: [kAXWindowCreatedNotification as CFString],
            refcon: Unmanaged.passUnretained(self).toOpaque())

        AppActivatedObserver.shared.subscribe { [weak self] event in
            self?.observerManager?.observeApp(pid: event.app.processIdentifier)
        }
        AppTerminatedObserver.shared.subscribe { [weak self] event in
            self?.observerManager?.removeAppObserver(pid: event.app.processIdentifier)
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observerManager?.observeApp(pid: app.processIdentifier)
        }
    }
}
