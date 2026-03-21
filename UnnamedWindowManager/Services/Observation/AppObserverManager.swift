import ApplicationServices

// Manages per-app AXObserver lifecycle: creation, run-loop registration, and cleanup.
final class AppObserverManager {
    private var appObservers: [pid_t: AXObserver] = [:]
    private let callback: AXObserverCallback
    private let notification: CFString
    private let refcon: UnsafeMutableRawPointer

    init(callback: @escaping AXObserverCallback, notification: CFString, refcon: UnsafeMutableRawPointer) {
        self.callback = callback
        self.notification = notification
        self.refcon = refcon
    }

    func observeApp(pid: pid_t) {
        guard appObservers[pid] == nil else { return }
        var axObs: AXObserver?
        guard AXObserverCreate(pid, callback, &axObs) == .success, let axObs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(axObs, appEl, notification, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        appObservers[pid] = axObs
    }

    func removeAppObserver(pid: pid_t) {
        guard let axObs = appObservers[pid] else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        appObservers.removeValue(forKey: pid)
    }
}
