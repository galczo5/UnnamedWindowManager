//
//  WindowEventMonitor.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

// C-compatible callback for app-level window-created notifications.
// refcon is unused; pid is derived from the element directly.
// The callback is delivered on the main thread (run loop source added to main).
private func appWindowCreatedCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    WindowSnapper.snapLeft(window: element, pid: pid)
}

final class WindowEventMonitor {
    static let shared = WindowEventMonitor()
    private init() {}

    /// AXObservers keyed by PID — used solely for app-level kAXWindowCreatedNotification.
    /// All access is on the main thread.
    private var appObservers: [pid_t: AXObserver] = [:]

    func start() {
        guard AXIsProcessTrusted() else { return }

        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID else { continue }
            subscribe(pid: app.processIdentifier)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
        subscribe(pid: app.processIdentifier)
    }

    private func subscribe(pid: pid_t) {
        guard appObservers[pid] == nil else { return }

        var axObs: AXObserver?
        guard AXObserverCreate(pid, appWindowCreatedCallback, &axObs) == .success,
              let axObs else { return }

        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(axObs, appElement, kAXWindowCreatedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        appObservers[pid] = axObs
    }
}
