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
        WindowFocusChangedObserver.shared.notify(WindowFocusChangedEvent())
        obs.applyDim(pid: pid)
    }
}

// Watches app activation and per-app focused-window changes to drive window dimming.
final class FocusObserver {
    static let shared = FocusObserver()
    private init() {}

    private var observerManager: AppObserverManager?
    private var retryWorkItem: DispatchWorkItem?

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
        WindowFocusChangedObserver.shared.notify(WindowFocusChangedEvent())
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
            FocusedWindowBorderService.shared.hide()
            return
        }
        let axWindow = ref as! AXUIElement

        let wid = windowID(of: axWindow)
        let hash = wid.map(UInt.init)
        let isManaged = hash.flatMap({ ResizeObserver.shared.keysByHash[$0] }) != nil

        // Tab switch detection: focused window is unmanaged, but a managed window from the same PID
        // is either off-screen or a known tab sibling of the new window.
        // Invalidate the cache first to avoid stale data from before the tab switch.
        retryWorkItem?.cancel()
        retryWorkItem = nil

        if !isManaged, let hash {
            OnScreenWindowCache.invalidate()
            let onScreen = OnScreenWindowCache.visibleHashes()
            let managedSiblings = ResizeObserver.shared.keysByPid[pid] ?? []
            // freshTabGroup uses bounds-matching (the authoritative check) and catches
            // new tabs whose hash was never in the existing slot's tabHashes.
            let freshTabGroup = TabDetector.tabSiblingHashes(of: hash, pid: pid)
            var swapped = false
            for siblingKey in managedSiblings {
                // Skip tab swap if sibling is in a root whose type doesn't match
                // the active root — avoids pulling windows across spaces.
                if let activeType = SharedRootStore.shared.activeRootType {
                    let inTiling = TilingRootStore.shared.rootID(containing: siblingKey) != nil
                    let inScrolling = ScrollingRootStore.shared.scrollingRootInfo(containing: siblingKey) != nil
                    if (inTiling && activeType != .tiling)
                        || (inScrolling && activeType != .scrolling) {
                        continue
                    }
                }
                if siblingKey.isSameTabGroup(hash: hash)
                    || !onScreen.contains(siblingKey.windowHash)
                    || freshTabGroup.contains(siblingKey.windowHash) {
                    ResizeObserver.shared.swapTab(oldKey: siblingKey, newWindow: axWindow, newHash: hash)
                    ReapplyHandler.reapplyAll()
                    swapped = true
                    break
                }
            }
            // If detection failed but managed siblings exist, the new window's bounds may not
            // have settled in CGWindowList yet. Poll until the hash appears.
            if !swapped, !managedSiblings.isEmpty {
                retryWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    SettlePoller.poll(condition: {
                        OnScreenWindowCache.invalidate()
                        return OnScreenWindowCache.visibleHashes().contains(hash)
                    }) { settled in
                        guard settled else { return }
                        self?.applyDim(pid: pid)
                    }
                }
                retryWorkItem = work
                DispatchQueue.main.async(execute: work)
                return
            }
        }

        guard let wid, let key = ResizeObserver.shared.keysByHash[UInt(wid)] else {
            WindowOpacityService.shared.restoreAll()
            FocusedWindowBorderService.shared.hide()
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
            FocusedWindowBorderService.shared.show(windowID: wid, axElement: axWindow)
        } else if let rootID = TilingRootStore.shared.rootID(containing: key) {
            WindowOpacityService.shared.dim(rootID: rootID, focusedHash: key.windowHash)
            FocusedWindowBorderService.shared.show(windowID: wid, axElement: axWindow)
        } else {
            WindowOpacityService.shared.restoreAll()
            FocusedWindowBorderService.shared.hide()
        }
    }

}
