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
            notifications: [
                kAXFocusedWindowChangedNotification as CFString,
                kAXMainWindowChangedNotification    as CFString,
            ],
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

        let wid = windowID(of: axWindow)
        let hash = wid.map(UInt.init)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        var titleRef: CFTypeRef?
        let title: String
        if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
           let t = titleRef as? String, !t.isEmpty { title = t } else { title = "(no title)" }
        let isManaged = hash.flatMap({ ResizeObserver.shared.keysByHash[$0] }) != nil
        let siblings = hash.map({ TabDetector.tabSiblingHashes(of: $0, pid: pid) }) ?? []
        Logger.shared.log("[focus] app=\"\(appName)\" title=\"\(title)\" pid=\(pid) hash=\(hash.map(String.init) ?? "nil") managed=\(isManaged) tabSiblings=\(siblings)")

        // Tab switch detection: focused window is unmanaged, but a managed window from the same PID
        // is either off-screen or a detected tab sibling (same bounds) of the new window.
        // Invalidate the cache first to avoid stale data from before the tab switch.
        if !isManaged, let hash {
            OnScreenWindowCache.invalidate()
            let onScreen = OnScreenWindowCache.visibleHashes()
            let managedSiblings = ResizeObserver.shared.keysByPid[pid] ?? []
            for siblingKey in managedSiblings {
                let isOffScreen = !onScreen.contains(siblingKey.windowHash)
                let isTabSibling = siblings.contains(siblingKey.windowHash)
                Logger.shared.log("[focus] tab-check: sibling=\(siblingKey.windowHash) offScreen=\(isOffScreen) tabSibling=\(isTabSibling)")
                if isOffScreen || isTabSibling {
                    Logger.shared.log("[focus] tab switch: pid=\(pid) old=\(siblingKey.windowHash) new=\(hash)")
                    ResizeObserver.shared.swapTab(oldKey: siblingKey, newWindow: axWindow, newHash: hash)
                    ReapplyHandler.reapplyAll()
                    break
                }
            }
        }

        guard let wid, let key = ResizeObserver.shared.keysByHash[UInt(wid)] else {
            WindowOpacityService.shared.restoreAll()
            return
        }

        if let info = ScrollingRootStore.shared.scrollingRootInfo(containing: key) {
            if info.centerHash != key.windowHash {
                ScrollingFocusService.scrollToCenter(key: key)
                if let updated = ScrollingRootStore.shared.scrollingRootInfo(containing: key) {
                    WindowOpacityService.shared.dim(rootID: updated.rootID, focusedHash: updated.centerHash)
                }
            } else {
                WindowOpacityService.shared.dim(rootID: info.rootID, focusedHash: info.centerHash)
            }
        } else if let rootID = TilingRootStore.shared.rootID(containing: key) {
            WindowOpacityService.shared.dim(rootID: rootID, focusedHash: key.windowHash)
        } else {
            WindowOpacityService.shared.restoreAll()
        }
    }

}
