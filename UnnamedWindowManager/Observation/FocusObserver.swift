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
        obs.applyDim(pid: pid)
    }
}

// Watches app activation and per-app focused-window changes to drive window dimming.
final class FocusObserver {
    static let shared = FocusObserver()
    private init() {}

    private var observerManager: AppObserverManager?

    func start() {
        observerManager = AppObserverManager(
            callback: focusChangedCallback,
            notification: kAXFocusedWindowChangedNotification as CFString,
            refcon: Unmanaged.passUnretained(self).toOpaque())
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(didActivateApp(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(didTerminateApp(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        if let app = NSWorkspace.shared.frontmostApplication {
            observerManager?.observeApp(pid: app.processIdentifier)
            applyDim(pid: app.processIdentifier)
        }
    }

    @objc private func didActivateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let pid = app.processIdentifier
        observerManager?.observeApp(pid: pid)
        NotificationCenter.default.post(name: .windowFocusChanged, object: nil)
        applyDim(pid: pid)
    }

    @objc private func didTerminateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        observerManager?.removeAppObserver(pid: app.processIdentifier)
    }

    func applyDim(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref
        else {
            WindowOpacityService.shared.restoreAll()
            return
        }
        let axWindow = ref as! AXUIElement

        guard let wid = windowID(of: axWindow),
              let key = ResizeObserver.shared.keysByHash[UInt(wid)] else {
            WindowOpacityService.shared.restoreAll()
            return
        }

        if let info = ScrollingTileService.shared.scrollingRootInfo(containing: key) {
            WindowOpacityService.shared.dim(rootID: info.rootID, focusedHash: info.centerHash)
        } else if let rootID = TileService.shared.rootID(containing: key) {
            WindowOpacityService.shared.dim(rootID: rootID, focusedHash: key.windowHash)
        } else {
            WindowOpacityService.shared.restoreAll()
        }
    }

}
