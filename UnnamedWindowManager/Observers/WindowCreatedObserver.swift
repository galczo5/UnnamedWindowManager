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
    private var appObservers: [pid_t: AXObserver] = [:]
    private let notifications: [CFString] = [kAXWindowCreatedNotification as CFString]

    func start() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        AppActivatedObserver.shared.subscribe("WindowCreatedObserver:start") { [weak self] event in
            self?.observeApp(pid: event.app.processIdentifier, refcon: refcon)
        }
        AppTerminatedObserver.shared.subscribe("WindowCreatedObserver:start") { [weak self] event in
            self?.removeAppObserver(pid: event.app.processIdentifier)
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observeApp(pid: app.processIdentifier, refcon: refcon)
        }
    }

    private func observeApp(pid: pid_t, refcon: UnsafeMutableRawPointer) {
        guard appObservers[pid] == nil else { return }
        var axObs: AXObserver?
        guard AXObserverCreate(pid, windowCreatedCallback, &axObs) == .success, let axObs else { return }
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
