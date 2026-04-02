import AppKit
import ApplicationServices

// C-compatible callback for kAXWindowCreatedNotification — must not capture Swift context.
private func windowCreatedCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Config.autoModeDelay) {
        AutoModeHandler.handleFocusChange()
    }
}

// Observes kAXWindowCreatedNotification for every active app and routes new windows
// into the active layout when auto mode is enabled.
final class WindowCreationObserver {
    static let shared = WindowCreationObserver()
    private init() {}

    private var observerManager: AppObserverManager?

    func start() {
        observerManager = AppObserverManager(
            callback: windowCreatedCallback,
            notifications: [kAXWindowCreatedNotification as CFString],
            refcon: Unmanaged.passUnretained(self).toOpaque())

        let wsNc = NSWorkspace.shared.notificationCenter
        wsNc.addObserver(self, selector: #selector(didActivateApp(_:)),
                         name: NSWorkspace.didActivateApplicationNotification, object: nil)
        wsNc.addObserver(self, selector: #selector(didTerminateApp(_:)),
                         name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(handleWindowFocusChanged),
                                               name: .windowFocusChanged, object: nil)

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observerManager?.observeApp(pid: app.processIdentifier)
        }
    }

    @objc private func handleWindowFocusChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.autoModeDelay) {
            AutoModeHandler.handleFocusChange()
        }
    }

    @objc private func didActivateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        observerManager?.observeApp(pid: app.processIdentifier)
    }

    @objc private func didTerminateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        observerManager?.removeAppObserver(pid: app.processIdentifier)
    }
}
