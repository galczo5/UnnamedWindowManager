import AppKit
import ApplicationServices

// `kAXUIElementDestroyedNotification` may not be bridged in all SDK versions.
private let kElementDestroyed  = "AXUIElementDestroyed" as CFString
private let kTitleChanged      = "AXTitleChanged"       as CFString

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

    /// Swaps the identity of a tiled tab: unregisters the old AX element, updates the slot tree,
    /// and registers the new element — without changing the layout position or size.
    func swapTab(oldKey: WindowSlot, newWindow: AXUIElement, newHash: UInt) {
        let pid = oldKey.pid

        // Remove old AX notifications.
        if let axObs = observers[pid], let oldElement = elements[oldKey] {
            AXObserverRemoveNotification(axObs, oldElement, kAXWindowMovedNotification        as CFString)
            AXObserverRemoveNotification(axObs, oldElement, kAXWindowResizedNotification    as CFString)
            AXObserverRemoveNotification(axObs, oldElement, kAXWindowMiniaturizedNotification as CFString)
            AXObserverRemoveNotification(axObs, oldElement, kElementDestroyed)
            AXObserverRemoveNotification(axObs, oldElement, kTitleChanged)
        }

        // Clean up old tracking (but don't touch the slot tree or layout).
        reapplyScheduler.cancel(key: oldKey)
        reapplying.remove(oldKey)
        elements.removeValue(forKey: oldKey)
        keysByHash.removeValue(forKey: oldKey.windowHash)
        keysByPid[pid]?.remove(oldKey)
        LayoutService.shared.clearCache(for: oldKey)

        // Update slot tree identity.
        SharedRootStore.shared.queue.sync(flags: .barrier) {
            for (id, rootSlot) in SharedRootStore.shared.roots {
                switch rootSlot {
                case .tiling(var root):
                    if TilingTreeMutationService().replaceLeafIdentity(
                        oldKey: oldKey, newPid: pid, newHash: newHash, in: &root
                    ) {
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

        // Invalidate the on-screen cache so pruneOffScreenWindows sees the new tab immediately.
        OnScreenWindowCache.invalidate()

        // Build new key preserving only identity fields; observe() fills the rest.
        var newKey = WindowSlot(pid: pid, windowHash: newHash,
                                id: UUID(), parentId: UUID(), order: 0, size: .zero,
                                isTabbed: true)
        newKey.tabHashes = TabDetector.tabSiblingHashes(of: newHash, pid: pid)
        observe(window: newWindow, pid: pid, key: newKey)
    }

    func stopObserving(key: WindowSlot, pid: pid_t) {
        guard let window = elements[key], let axObs = observers[pid] else { return }
        AXObserverRemoveNotification(axObs, window, kAXWindowMovedNotification        as CFString)
        AXObserverRemoveNotification(axObs, window, kAXWindowResizedNotification    as CFString)
        AXObserverRemoveNotification(axObs, window, kAXWindowMiniaturizedNotification as CFString)
        AXObserverRemoveNotification(axObs, window, kElementDestroyed)
        AXObserverRemoveNotification(axObs, window, kTitleChanged)
        cleanup(key: key, pid: pid)
    }

    func window(for key: WindowSlot) -> AXUIElement? {
        elements[key]
    }

    // MARK: – Internal (called from C callback on main thread)

    func handle(element: AXUIElement, notification: String, pid: pid_t) {
        // windowID(of:) fails for destroyed elements; fall back to CFEqual identity search.
        let resolvedKey: WindowSlot?
        if let wid = windowID(of: element) {
            resolvedKey = keysByHash[UInt(wid)]
            // Not tracked — check if it's a tab of a managed window from the same PID.
            if resolvedKey == nil, notification != (kElementDestroyed as String) {
                let hash = UInt(wid)
                for siblingKey in keysByPid[pid] ?? [] {
                    if siblingKey.isSameTabGroup(hash: hash) {
                        swapTab(oldKey: siblingKey, newWindow: element, newHash: hash)
                        ReapplyHandler.reapplyAll()
                        return
                    }
                }
                return
            }
        } else {
            resolvedKey = keysByPid[pid]?.first { elements[$0].map { CFEqual($0, element) } == true }
        }
        guard let key = resolvedKey else { return }

        let isScrolling = ScrollingRootStore.shared.isTracked(key)

        if notification == (kTitleChanged as String) {
            return
        }

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

        guard TilingRootStore.shared.isTracked(key) || isScrolling else { return }
        guard !reapplying.contains(key) else { return }

        let isResize = notification == (kAXWindowResizedNotification as String)

        // While a drag is in progress, update the drop-zone overlay in real time (tiling only).
        if !isScrolling && !isResize && NSEvent.pressedMouseButtons != 0 {
            reapplyScheduler.updateDragOverlay(forKey: key, element: element, elements: elements)
        }

        reapplyScheduler.schedule(key: key, isResize: isResize, isScrolling: isScrolling)
    }

    // MARK: – Private

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
            s.tabHashes = TabDetector.tabSiblingHashes(of: newHash, pid: newPid)
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
                ScrollingRootStore.shared.removeWindow(key, screen: screen)
            } else {
                TilingSnapService.shared.removeAndReflow(key, screen: screen)
            }
        } else {
            TilingSnapService.shared.remove(key)
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
