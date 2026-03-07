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

// Observes window creation and app activation events to auto-snap new windows into the layout.
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

    func handleWindowCreated(pid: pid_t) {
        // Capture screen state NOW — before the new window appears in CGWindowList.
        var screenWasEmpty = false
        if Config.autoOrganize {
            let existing = windowsOnScreen()
            if existing.isEmpty {
                screenWasEmpty = true
            } else {
                Logger.shared.log("autoOrganize skipped — \(existing.count) window(s) on screen: \(existing.joined(separator: ", "))")
            }
        }
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
        if Config.autoOrganize && screenWasEmpty {
            Logger.shared.log("autoOrganize triggered for pid=\(pid)")
            OrganizeHandler.organize()
            return
        }

        guard Config.autoSnap else { return }
        let hasLayout = SnapService.shared.snapshotVisibleRoot() != nil
        guard hasLayout else {
            Logger.shared.log("autoSnap skipped — no layout active (pid=\(pid))")
            return
        }
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success
        else { return }
        let window = ref as! AXUIElement
        guard !SnapService.shared.isTracked(windowSlot(for: window, pid: pid)) else { return }
        Logger.shared.log("autoSnap triggered for pid=\(pid)")
        SnapHandler.snapLeft(window: window, pid: pid)
    }

    private func windowsOnScreen() -> [String] {
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return list.compactMap {
            guard let layer = $0[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid   = $0[kCGWindowOwnerPID as String] as? Int,
                  pid_t(pid) != ownPID
            else { return nil }
            let app   = $0[kCGWindowOwnerName as String] as? String ?? "?"
            let title = $0[kCGWindowName as String] as? String ?? ""
            return title.isEmpty ? app : "\(app) — \(title)"
        }
    }
}
