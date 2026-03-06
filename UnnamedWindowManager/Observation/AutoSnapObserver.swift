//
//  AutoSnapObserver.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

// C-compatible callback — must not capture any Swift context.
// refcon is Unmanaged<AutoSnapObserver> passed via AXObserverAddNotification.
private func autoSnapCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let obs = Unmanaged<AutoSnapObserver>.fromOpaque(refcon).takeUnretainedValue()
    obs.handleWindowCreated(pid: pid)
}

final class AutoSnapObserver {
    static let shared = AutoSnapObserver()
    private init() {}

    private var appObservers: [pid_t: AXObserver] = [:]

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(didActivateApp(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(didTerminateApp(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        // Observe the already-frontmost app so kAXWindowCreatedNotification is
        // registered even if the user never switches away from it.
        if let app = NSWorkspace.shared.frontmostApplication {
            observeApp(pid: app.processIdentifier)
        }
    }

    @objc private func didActivateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let pid = app.processIdentifier
        observeApp(pid: pid)
        snapFocusedWindow(pid: pid)
    }

    @objc private func didTerminateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        removeAppObserver(pid: app.processIdentifier)
    }

    // Called from autoSnapCallback on the main thread.
    func handleWindowCreated(pid: pid_t) {
        // Capture screen state NOW — before the new window appears in CGWindowList.
        let screenWasEmpty = Config.autoOrganize && !hasAnyWindowOnScreen()
        // Defer by one run-loop pass so the new window has time to receive focus
        // before kAXFocusedWindowAttribute is queried.
        DispatchQueue.main.async { [weak self] in
            self?.snapFocusedWindow(pid: pid, screenWasEmpty: screenWasEmpty)
        }
    }

    // MARK: - Private

    private func observeApp(pid: pid_t) {
        guard appObservers[pid] == nil else { return }
        var axObs: AXObserver?
        guard AXObserverCreate(pid, autoSnapCallback, &axObs) == .success, let axObs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(axObs, appEl, kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        appObservers[pid] = axObs
    }

    private func removeAppObserver(pid: pid_t) {
        guard let axObs = appObservers[pid] else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        appObservers.removeValue(forKey: pid)
    }

    private func snapFocusedWindow(pid: pid_t, screenWasEmpty: Bool = false) {
        let hasLayout = SnapService.shared.snapshotVisibleRoot() != nil
        guard (Config.autoSnap && hasLayout) || screenWasEmpty else { return }
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success
        else { return }
        SnapHandler.snapLeft(window: ref as! AXUIElement, pid: pid)
    }

    private func hasAnyWindowOnScreen() -> Bool {
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        return list.contains {
            guard let layer = $0[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid   = $0[kCGWindowOwnerPID as String] as? Int
            else { return false }
            return pid_t(pid) != ownPID
        }
    }
}
