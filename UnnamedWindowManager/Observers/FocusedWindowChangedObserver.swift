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
    private var appObservers: [pid_t: AXObserver] = [:]
    private let notifications: [CFString] = [
        kAXFocusedWindowChangedNotification as CFString,
        kAXMainWindowChangedNotification    as CFString,
    ]

    func start() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        AppActivatedObserver.shared.subscribe { [weak self] event in
            guard let self else { return }
            let pid = event.app.processIdentifier
            observeApp(pid: pid, refcon: refcon)
            notify(FocusedWindowChangedEvent(pid: pid))
        }
        AppTerminatedObserver.shared.subscribe { [weak self] event in
            self?.removeAppObserver(pid: event.app.processIdentifier)
        }

        if let app = NSWorkspace.shared.frontmostApplication {
            observeApp(pid: app.processIdentifier, refcon: refcon)
            notify(FocusedWindowChangedEvent(pid: app.processIdentifier))
        }
    }

    private func observeApp(pid: pid_t, refcon: UnsafeMutableRawPointer) {
        guard appObservers[pid] == nil else { return }
        var axObs: AXObserver?
        guard AXObserverCreate(pid, focusChangedCallback, &axObs) == .success, let axObs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        for n in notifications {
            AXObserverAddNotification(axObs, appEl, n, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        appObservers[pid] = axObs
    }

    private func removeAppObserver(pid: pid_t) {
        guard let axObs = appObservers[pid] else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        appObservers.removeValue(forKey: pid)
    }
}
