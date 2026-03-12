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
    let obs = Unmanaged<FocusObserver>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .windowFocusChanged, object: nil)
    }
    // TODO: Infinite loop here!
    //    obs.applyDimForFrontmostWindow(pid: pid)
}

// Watches app activation and per-app focused-window changes to drive window dimming.
final class FocusObserver {
    static let shared = FocusObserver()
    private init() {}

    private var appObservers: [pid_t: AXObserver] = [:]

    func start() {
        Logger.shared.log("start")
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(didActivateApp(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(didTerminateApp(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        if let app = NSWorkspace.shared.frontmostApplication {
            observeApp(pid: app.processIdentifier)
            // TODO: Infinite loop here!
//            applyDimForFrontmostWindow(pid: app.processIdentifier)
        }
    }

    @objc private func didActivateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let pid = app.processIdentifier
        observeApp(pid: pid)
        NotificationCenter.default.post(name: .windowFocusChanged, object: nil)
        // TODO: Infinite loop here!
//        applyDimForFrontmostWindow(pid: pid)
    }

    @objc private func didTerminateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        removeAppObserver(pid: app.processIdentifier)
    }

    func applyDimForFrontmostWindow(pid: pid_t) {
        Logger.shared.log("applyDimForFrontmostWindow: pid=\(pid)")
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success
        else {
            WindowOpacityService.shared.restoreAll()
            return
        }
        let axWindow = ref as! AXUIElement

        // Raise the focused window first so the window server reflects the correct
        // Z-order before the overlay is positioned below it.
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)

        let elements = ResizeObserver.shared.elements
        if let (key, _) = elements.first(where: { CFEqual($0.value, axWindow) }),
           !ScrollingTileService.shared.isTracked(key),
           let rootID = TileService.shared.rootID(containing: key) {
            let hash = key.windowHash
            DispatchQueue.main.async {
                WindowOpacityService.shared.dim(rootID: rootID, focusedHash: hash)
            }
        } else {
            // Focused window is not managed or is in a scrolling root; hide all dim overlays.
            WindowOpacityService.shared.restoreAll()
        }
    }

    private func observeApp(pid: pid_t) {
        guard appObservers[pid] == nil else { return }
        var axObs: AXObserver?
        guard AXObserverCreate(pid, focusChangedCallback, &axObs) == .success, let axObs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(axObs, appEl, kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        appObservers[pid] = axObs
    }

    private func removeAppObserver(pid: pid_t) {
        guard let axObs = appObservers[pid] else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        appObservers.removeValue(forKey: pid)
    }
}
