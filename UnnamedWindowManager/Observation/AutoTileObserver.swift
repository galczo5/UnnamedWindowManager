import AppKit
import ApplicationServices

// C-compatible callback — must not capture any Swift context.
// refcon is Unmanaged<AutoTileObserver> passed via AXObserverAddNotification.
private func autoTileCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    let obs = Unmanaged<AutoTileObserver>.fromOpaque(refcon).takeUnretainedValue()
    obs.handleWindowCreated(pid: pid)
}

// Observes window creation and app activation events to auto-tile new windows into the layout.
final class AutoTileObserver {
    static let shared = AutoTileObserver()
    private init() {}

    private var appObservers: [pid_t: AXObserver] = [:]

    func start() {
        Logger.shared.log("start")
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
        tileFocusedWindow(pid: pid)
    }

    @objc private func didTerminateApp(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        removeAppObserver(pid: app.processIdentifier)
    }

    func handleWindowCreated(pid: pid_t) {
        Logger.shared.log("handleWindowCreated: pid=\(pid)")
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
            self?.tileFocusedWindow(pid: pid, screenWasEmpty: screenWasEmpty)
        }
    }

    // MARK: - Private

    private func observeApp(pid: pid_t) {
        guard appObservers[pid] == nil else { return }
        var axObs: AXObserver?
        guard AXObserverCreate(pid, autoTileCallback, &axObs) == .success, let axObs else { return }
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

    private func tileFocusedWindow(pid: pid_t, screenWasEmpty: Bool = false) {
        if Config.autoOrganize && screenWasEmpty {
            Logger.shared.log("autoOrganize triggered for pid=\(pid)")
            TileAllHandler.tileAll()
            return
        }

        guard Config.autoSnap else { return }
        let hasLayout = TileService.shared.snapshotVisibleRoot() != nil
        guard hasLayout else {
            Logger.shared.log("autoTile skipped — no layout active (pid=\(pid))")
            return
        }
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success
        else { return }
        let window = ref as! AXUIElement
        guard !TileService.shared.isTracked(windowSlot(for: window, pid: pid)) else { return }
        // If a tracked window for this pid is at the same position, the new window is a tab — skip.
        guard !isTabOfTrackedWindow(window, pid: pid) else {
            Logger.shared.log("autoTile skipped — new window is a tab of a tracked window (pid=\(pid))")
            return
        }
        Logger.shared.log("autoTile triggered for pid=\(pid)")
        pruneStaleSlots(for: pid)
        TileHandler.tileLeft(window: window, pid: pid)
    }

    /// Returns true if `window` appears at the same screen position as any already-tracked window
    /// for `pid`, indicating it is a tab of that window rather than an independent new window.
    private func isTabOfTrackedWindow(_ window: AXUIElement, pid: pid_t) -> Bool {
        guard let trackedKeys = ResizeObserver.shared.keysByPid[pid], !trackedKeys.isEmpty else { return false }
        guard let origin = readOrigin(of: window) else { return false }
        let elements = ResizeObserver.shared.elements
        for key in trackedKeys {
            guard let trackedElement = elements[key],
                  let trackedOrigin = readOrigin(of: trackedElement) else { continue }
            if abs(origin.x - trackedOrigin.x) < 10 && abs(origin.y - trackedOrigin.y) < 10 {
                return true
            }
        }
        return false
    }

    private func pruneStaleSlots(for pid: pid_t) {
        guard let trackedKeys = ResizeObserver.shared.keysByPid[pid], !trackedKeys.isEmpty else { return }
        let knownWIDs = allWindowIDs(for: pid)
        guard !knownWIDs.isEmpty else { return }
        let screen = NSScreen.main
        for key in trackedKeys {
            guard !knownWIDs.contains(key.windowHash) else { continue }
            Logger.shared.log("pruning stale slot: pid=\(pid) hash=\(key.windowHash)")
            ResizeObserver.shared.stopObserving(key: key, pid: pid)
            if let screen {
                TileService.shared.removeAndReflow(key, screen: screen)
            } else {
                TileService.shared.remove(key)
            }
        }
    }

    private func allWindowIDs(for pid: pid_t) -> Set<UInt> {
        guard let list = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var ids = Set<UInt>()
        for info in list {
            guard let p = info[kCGWindowOwnerPID as String] as? Int, pid_t(p) == pid,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            ids.insert(UInt(wid))
        }
        return ids
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
