import AppKit
import ApplicationServices

// `kAXUIElementDestroyedNotification` may not be bridged in all SDK versions.
private let kElementDestroyed = "AXUIElementDestroyed" as CFString

// Tracks AX move/resize/destroy notifications for all tiled windows and drives layout reapplication.
final class ResizeObserver {
    static let shared = ResizeObserver()
    private init() {}

    // All mutable state is accessed only on the main thread.
    var observers:  [pid_t: AXObserver]                  = [:]
    var elements:   [WindowSlot: AXUIElement]             = [:]
    var keysByPid:  [pid_t: Set<WindowSlot>]              = [:]
    var keysByHash: [UInt: WindowSlot]                    = [:]
    /// Keys whose reapply is in-flight; prevents re-entrancy from the resulting AX notification.
    var reapplying: Set<WindowSlot>                       = []
    private(set) lazy var reapplyScheduler = DragReapplyScheduler(observer: self)

    // MARK: – Public

    func observe(window: AXUIElement, pid: pid_t, key: WindowSlot) {
        guard elements[key] == nil else {
            return
        }

        elements[key] = window
        keysByPid[pid, default: []].insert(key)
        keysByHash[key.windowHash] = key

        guard let axObs = axObserver(for: pid) else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(axObs, window, kAXWindowMovedNotification        as CFString, refcon)
        AXObserverAddNotification(axObs, window, kAXWindowResizedNotification    as CFString, refcon)
        AXObserverAddNotification(axObs, window, kAXWindowMiniaturizedNotification as CFString, refcon)
        AXObserverAddNotification(axObs, window, kElementDestroyed,                             refcon)
    }

    func stopObserving(key: WindowSlot, pid: pid_t) {
        guard let window = elements[key], let axObs = observers[pid] else { return }
        AXObserverRemoveNotification(axObs, window, kAXWindowMovedNotification        as CFString)
        AXObserverRemoveNotification(axObs, window, kAXWindowResizedNotification    as CFString)
        AXObserverRemoveNotification(axObs, window, kAXWindowMiniaturizedNotification as CFString)
        AXObserverRemoveNotification(axObs, window, kElementDestroyed)
        cleanup(key: key, pid: pid)
    }

    func window(for key: WindowSlot) -> AXUIElement? {
        elements[key]
    }

    // MARK: – Internal (called from C callback on main thread)

    func handle(element: AXUIElement, notification: String, pid: pid_t) {
        // windowID(of:) fails for destroyed elements; fall back to CFEqual identity search.
        guard let key: WindowSlot = {
            if let wid = windowID(of: element) { return keysByHash[UInt(wid)] }
            return keysByPid[pid]?.first { elements[$0].map { CFEqual($0, element) } == true }
        }() else { return }

        let isScrolling = ScrollingTileService.shared.isTracked(key)

        let eventLabel = notification == (kAXWindowResizedNotification as String) ? "resize" : "move"
        Logger.shared.log("[\(eventLabel)] key=\(key.windowHash) pid=\(pid) scrolling=\(isScrolling)")

        if notification == kElementDestroyed as String {
            removeWindow(key: key, pid: pid, isScrolling: isScrolling)
            return
        }

        if notification == (kAXWindowMiniaturizedNotification as String) {
            removeWindow(key: key, pid: pid, isScrolling: isScrolling)
            return
        }

        if notification == (kAXWindowResizedNotification as String) {
            var ref: CFTypeRef?
            let isFullScreen = AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &ref) == .success
                               && (ref as? Bool) == true
            if isFullScreen {
                removeWindow(key: key, pid: pid, isScrolling: isScrolling)
                return
            }
        }

        guard TileService.shared.isTracked(key) || isScrolling else { return }
        guard !reapplying.contains(key) else { return }

        let isResize = notification == (kAXWindowResizedNotification as String)

        // While a drag is in progress, update the drop-zone overlay in real time (tiling only).
        if !isScrolling && !isResize && NSEvent.pressedMouseButtons != 0 {
            reapplyScheduler.updateDragOverlay(forKey: key, element: element, elements: elements)
        }

        reapplyScheduler.schedule(key: key, isResize: isResize, isScrolling: isScrolling)
    }

    // MARK: – Private

    func axObserver(for pid: pid_t) -> AXObserver? {
        if let existing = observers[pid] { return existing }

        var axObs: AXObserver?
        let err = AXObserverCreate(pid, axNotificationCallback, &axObs)
        guard err == .success, let axObs else { return nil }
        observers[pid] = axObs
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        return axObs
    }

    private func removeWindow(key: WindowSlot, pid: pid_t, isScrolling: Bool) {
        WindowOpacityService.shared.restore(hash: key.windowHash)
        if let screen = NSScreen.main {
            if isScrolling {
                ScrollingTileService.shared.removeWindow(key, screen: screen)
            } else {
                TileService.shared.removeAndReflow(key, screen: screen)
            }
        } else {
            TileService.shared.remove(key)
        }
        cleanup(key: key, pid: pid)
        WindowVisibilityManager.shared.windowRemoved(key)
        ReapplyHandler.reapplyAll()
    }

    func cleanup(key: WindowSlot, pid: pid_t) {
        reapplyScheduler.cancel(key: key)
        reapplyScheduler.overlay.hide()
        reapplying.remove(key)
        elements.removeValue(forKey: key)
        keysByHash.removeValue(forKey: key.windowHash)
        keysByPid[pid]?.remove(key)
        LayoutService.shared.clearCache(for: key)
        ScrollingLayoutService.shared.clearCache(for: key)

        if keysByPid[pid]?.isEmpty == true {
            if let axObs = observers[pid] {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
            }
            observers.removeValue(forKey: pid)
            keysByPid.removeValue(forKey: pid)
        }
    }

}
