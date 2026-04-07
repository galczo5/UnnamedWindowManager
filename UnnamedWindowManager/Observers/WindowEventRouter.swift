import AppKit
import ApplicationServices

private let kElementDestroyed = "AXUIElementDestroyed" as CFString
private let kTitleChanged     = "AXTitleChanged"       as CFString

// C-compatible callback — must not capture any Swift context.
// refcon is Unmanaged<WindowEventRouter> passed via AXObserverAddNotification.
private func axNotificationCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let router = Unmanaged<WindowEventRouter>.fromOpaque(refcon).takeUnretainedValue()
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    // AXObserver is added to the main run loop — we are on the main thread.
    router.handle(element: element, notification: notification as String, pid: pid)
}

// Creates per-PID AXObserver instances, registers per-window AX notifications,
// and routes callbacks to the appropriate typed observer.
final class WindowEventRouter {
    static let shared = WindowEventRouter()
    private init() {}

    private var observers: [pid_t: AXObserver] = [:]

    // MARK: - Public

    func observe(window: AXUIElement, pid: pid_t, key: WindowSlot) {
        guard WindowTracker.shared.elements[key] == nil else { return }
        WindowTracker.shared.register(key: key, element: window, pid: pid)

        guard let axObs = axObserver(for: pid) else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(axObs, window, kAXWindowMovedNotification        as CFString, refcon)
        AXObserverAddNotification(axObs, window, kAXWindowResizedNotification      as CFString, refcon)
        AXObserverAddNotification(axObs, window, kAXWindowMiniaturizedNotification as CFString, refcon)
        AXObserverAddNotification(axObs, window, kElementDestroyed,                             refcon)
        AXObserverAddNotification(axObs, window, kTitleChanged,                                 refcon)

        // For tabbed windows, also watch move notifications on sibling tab elements so that
        // moving the window while a non-representative tab is active is still detected.
        if !key.tabHashes.isEmpty {
            let siblingHashes = key.tabHashes.filter { $0 != key.windowHash }
            let axApp = AXUIElementCreateApplication(pid)
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
               let wins = ref as? [AXUIElement] {
                for sibling in wins {
                    if let sibWid = windowID(of: sibling),
                       siblingHashes.contains(UInt(sibWid)) {
                        AXObserverAddNotification(axObs, sibling, kAXWindowMovedNotification as CFString, refcon)
                    }
                }
            }
        }
    }

    func stopObserving(key: WindowSlot, pid: pid_t) {
        guard let window = WindowTracker.shared.elements[key],
              let axObs = observers[pid] else { return }
        AXObserverRemoveNotification(axObs, window, kAXWindowMovedNotification        as CFString)
        AXObserverRemoveNotification(axObs, window, kAXWindowResizedNotification      as CFString)
        AXObserverRemoveNotification(axObs, window, kAXWindowMiniaturizedNotification as CFString)
        AXObserverRemoveNotification(axObs, window, kElementDestroyed)
        AXObserverRemoveNotification(axObs, window, kTitleChanged)
        WindowTracker.shared.cleanup(key: key, pid: pid)
        cleanupPidIfEmpty(pid)
    }

    func swapTab(oldKey: WindowSlot, newWindow: AXUIElement, newHash: UInt) {
        let pid = oldKey.pid
        let tracker = WindowTracker.shared

        // Remove old AX notifications.
        if let axObs = observers[pid], let oldElement = tracker.elements[oldKey] {
            AXObserverRemoveNotification(axObs, oldElement, kAXWindowMovedNotification        as CFString)
            AXObserverRemoveNotification(axObs, oldElement, kAXWindowResizedNotification      as CFString)
            AXObserverRemoveNotification(axObs, oldElement, kAXWindowMiniaturizedNotification as CFString)
            AXObserverRemoveNotification(axObs, oldElement, kElementDestroyed)
            AXObserverRemoveNotification(axObs, oldElement, kTitleChanged)
        }

        // Clean up old tracking (but don't touch the slot tree or layout).
        tracker.reapplyScheduler.cancel(key: oldKey)
        tracker.reapplying.remove(oldKey)
        tracker.elements.removeValue(forKey: oldKey)
        tracker.keysByHash.removeValue(forKey: oldKey.windowHash)
        tracker.keysByPid[pid]?.remove(oldKey)

        // Update slot tree identity.
        SharedRootStore.shared.queue.sync(flags: .barrier) {
            for (id, rootSlot) in SharedRootStore.shared.roots {
                switch rootSlot {
                case .tiling(var root):
                    if root.replaceLeafIdentity(oldKey: oldKey, newPid: pid, newHash: newHash) {
                        SharedRootStore.shared.roots[id] = .tiling(root)
                        return
                    }
                case .scrolling(var root):
                    if replaceScrollingLeafIdentity(oldHash: oldKey.windowHash,
                                                    newPid: pid, newHash: newHash, in: &root) {
                        SharedRootStore.shared.roots[id] = .scrolling(root)
                        return
                    }
                }
            }
        }

        WindowOnScreenCache.invalidate()

        var newKey = WindowSlot(pid: pid, windowHash: newHash,
                                id: UUID(), parentId: UUID(), order: 0, size: .zero,
                                isTabbed: true)
        newKey.tabHashes = WindowTabDetector.tabSiblingHashes(of: newHash, pid: pid)
        observe(window: newWindow, pid: pid, key: newKey)
    }

    /// Removes a window from all stores and tracking. Used for destroyed, miniaturized,
    /// and fullscreen events where AX notifications cannot or need not be unregistered.
    func removeWindow(key: WindowSlot, pid: pid_t, isScrolling: Bool) {
        WindowOpacityService.shared.restore(hash: key.windowHash)
        if let screen = NSScreen.main {
            if isScrolling {
                ScrollingRootStore.shared.removeWindow(key, screen: screen)
            } else {
                TilingService.shared.removeAndReflow(key, screen: screen)
            }
        } else {
            TilingService.shared.remove(key)
        }
        WindowTracker.shared.cleanup(key: key, pid: pid)
        cleanupPidIfEmpty(pid)
        ReapplyHandler.reapplyAll()
    }

    // MARK: - Internal (called from C callback on main thread)

    func handle(element: AXUIElement, notification: String, pid: pid_t) {
        let tracker = WindowTracker.shared
        // windowID(of:) fails for destroyed elements; fall back to CFEqual identity search.
        let resolvedKey: WindowSlot?
        if let wid = windowID(of: element) {
            resolvedKey = tracker.keysByHash[UInt(wid)]
            // Not tracked — check if it's a tab of a managed window from the same PID.
            if resolvedKey == nil, notification != (kElementDestroyed as String) {
                let hash = UInt(wid)
                for siblingKey in tracker.keysByPid[pid] ?? [] {
                    if siblingKey.isSameTabGroup(hash: hash) {
                        swapTab(oldKey: siblingKey, newWindow: element, newHash: hash)
                        ReapplyHandler.reapplyAll()
                        return
                    }
                }
                return
            }
        } else {
            resolvedKey = tracker.keysByPid[pid]?.first { tracker.elements[$0].map { CFEqual($0, element) } == true }
        }
        guard let key = resolvedKey else { return }

        switch notification {
        case "AXTitleChanged":
            WindowTitleChangedObserver.shared.notify(WindowTitleChangedEvent(key: key, pid: pid))

        case "AXUIElementDestroyed":
            WindowDestroyedObserver.shared.notify(WindowDestroyedEvent(key: key, pid: pid))

        case kAXWindowMiniaturizedNotification as String:
            WindowMiniaturizedObserver.shared.notify(WindowMiniaturizedEvent(key: key, pid: pid))

        case kAXWindowResizedNotification as String:
            var ref: CFTypeRef?
            let isFullScreen = AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &ref) == .success
                               && (ref as? Bool) == true
            WindowResizedObserver.shared.notify(WindowResizedEvent(key: key, element: element, pid: pid, isFullScreen: isFullScreen))

        case kAXWindowMovedNotification as String:
            WindowMovedObserver.shared.notify(WindowMovedEvent(key: key, element: element, pid: pid))

        default:
            break
        }
    }

    // MARK: - Private

    private func axObserver(for pid: pid_t) -> AXObserver? {
        if let existing = observers[pid] { return existing }
        var axObs: AXObserver?
        let err = AXObserverCreate(pid, axNotificationCallback, &axObs)
        guard err == .success, let axObs else { return nil }
        observers[pid] = axObs
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        return axObs
    }

    private func cleanupPidIfEmpty(_ pid: pid_t) {
        if WindowTracker.shared.keysByPid[pid]?.isEmpty == true {
            if let axObs = observers[pid] {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
            }
            observers.removeValue(forKey: pid)
            WindowTracker.shared.keysByPid.removeValue(forKey: pid)
        }
    }

    private func replaceScrollingLeafIdentity(
        oldHash: UInt, newPid: pid_t, newHash: UInt,
        in root: inout ScrollingRootSlot
    ) -> Bool {
        func replaced(_ w: WindowSlot) -> WindowSlot {
            var s = WindowSlot(pid: newPid, windowHash: newHash,
                               id: w.id, parentId: w.parentId, order: w.order, size: w.size,
                               gaps: w.gaps, fraction: w.fraction,
                               preTileOrigin: w.preTileOrigin, preTileSize: w.preTileSize,
                               isTabbed: true)
            s.tabHashes = WindowTabDetector.tabSiblingHashes(of: newHash, pid: newPid)
            return s
        }
        if case .window(let w) = root.center, w.windowHash == oldHash {
            root.center = .window(replaced(w))
            return true
        }
        if case .stacking(var s) = root.left,
           let idx = s.children.firstIndex(where: { $0.windowHash == oldHash }) {
            s.children[idx] = replaced(s.children[idx])
            root.left = .stacking(s)
            return true
        }
        if case .stacking(var s) = root.right,
           let idx = s.children.firstIndex(where: { $0.windowHash == oldHash }) {
            s.children[idx] = replaced(s.children[idx])
            root.right = .stacking(s)
            return true
        }
        return false
    }
}
