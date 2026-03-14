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
    var pendingReapply: [WindowSlot: DispatchWorkItem]    = [:]
    let overlay = SwapOverlay()

    private var lastDropTarget: DropTarget?
    private var dropTargetEnteredAt: Date?

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
        AXObserverAddNotification(axObs, window, kAXWindowMovedNotification   as CFString, refcon)
        AXObserverAddNotification(axObs, window, kAXWindowResizedNotification as CFString, refcon)
        AXObserverAddNotification(axObs, window, kElementDestroyed,                        refcon)
    }

    func stopObserving(key: WindowSlot, pid: pid_t) {
        guard let window = elements[key], let axObs = observers[pid] else { return }
        AXObserverRemoveNotification(axObs, window, kAXWindowMovedNotification   as CFString)
        AXObserverRemoveNotification(axObs, window, kAXWindowResizedNotification as CFString)
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
            return
        }

        guard TileService.shared.isTracked(key) || isScrolling else { return }
        guard !reapplying.contains(key) else { return }

        let isResize = notification == (kAXWindowResizedNotification as String)

        // While a drag is in progress, update the drop-zone overlay in real time (tiling only).
        if !isScrolling && !isResize && NSEvent.pressedMouseButtons != 0 {
            let drop = ReapplyHandler.findDropTarget(forKey: key)
            updateTrackedDropTarget(drop)
            overlay.update(dropTarget: drop, draggedWindow: element, elements: elements)
        }

        scheduleReapplyWhenMouseUp(key: key, isResize: isResize, isScrolling: isScrolling)
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

    func cleanup(key: WindowSlot, pid: pid_t) {
        pendingReapply[key]?.cancel()
        pendingReapply.removeValue(forKey: key)
        overlay.hide()
        elements.removeValue(forKey: key)
        keysByHash.removeValue(forKey: key.windowHash)
        reapplying.remove(key)
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

    // MARK: - Reapply

    /// Polls every 10 ms until no mouse button is held, then reapplies the tile.
    /// Any in-progress poll for the same key is cancelled before scheduling a new one.
    /// - Parameter isResize: true when triggered by a resize notification — accepts the
    ///   new size and reflows all snapped windows; false for move — restores position only.
    /// - Parameter isScrolling: true for windows in a ScrollingRootSlot — always snaps back
    ///   to slot position/size without fraction adjustment or drop-zone logic.
    func scheduleReapplyWhenMouseUp(key: WindowSlot, isResize: Bool, isScrolling: Bool) {
        pendingReapply[key]?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReapply.removeValue(forKey: key)

            if NSEvent.pressedMouseButtons != 0 {
                self.scheduleReapplyWhenMouseUp(key: key, isResize: isResize, isScrolling: isScrolling)
                return
            }

            self.overlay.hide()

            guard !self.reapplying.contains(key),
                  self.elements[key] != nil else { return }

            if isScrolling {
                self.reapplying.insert(key)
                if let screen = NSScreen.main {
                    let isCenterResize = isResize && ScrollingTileService.shared.isCenterWindow(key)
                    if isCenterResize,
                       let axElement = self.elements[key],
                       let actualSize = readSize(of: axElement) {
                        ScrollingResizeService().applyResize(
                            centerKey: key, actualWidth: actualSize.width, screen: screen)
                    }
                    ScrollingLayoutService.shared.clearCache(for: key)
                    LayoutService.shared.applyLayout(screen: screen, scrollingSidesPositionOnly: isCenterResize)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let windows = Set(ScrollingTileService.shared.leavesInVisibleScrollingRoot()
                            .compactMap { (slot: Slot) -> WindowSlot? in
                                guard case .window(let w) = slot else { return nil }
                                return w
                            })
                        PostResizeValidator.checkAndFixRefusals(windows: windows, screen: screen)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.reapplying.remove(key)
                }
                return
            }

            let hoverStart = self.dropTargetEnteredAt
            self.lastDropTarget = nil
            self.dropTargetEnteredAt = nil

            if isResize {
                guard let screen = NSScreen.main,
                      let axElement = self.elements[key],
                      let actualSize = readSize(of: axElement) else { return }

                TileService.shared.resize(key: key, actualSize: actualSize, screen: screen)
                ReapplyHandler.reapplyAll()
            } else {
                // Move: directional insert, center swap, or restore.
                let hoverDuration = hoverStart.map { Date().timeIntervalSince($0) } ?? 0
                let dropAllowed = hoverDuration >= Config.dropZoneHoverDelay
                if dropAllowed, let drop = ReapplyHandler.findDropTarget(forKey: key) {
                    if drop.zone == .center {
                        TileService.shared.swap(key, drop.window)
                    } else if let screen = NSScreen.main {
                        TileService.shared.insertAdjacent(dragged: key, target: drop.window,
                                                          zone: drop.zone, screen: screen)
                    }
                    ReapplyHandler.reapplyAll()
                } else {
                    guard let storedElement = self.elements[key] else { return }
                    self.reapplying.insert(key)
                    ReapplyHandler.reapply(window: storedElement, key: key)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.reapplying.remove(key)
                    }
                }
            }
        }

        pendingReapply[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: work)
    }

    private func updateTrackedDropTarget(_ newTarget: DropTarget?) {
        guard let new = newTarget else {
            lastDropTarget = nil
            dropTargetEnteredAt = nil
            return
        }
        if let last = lastDropTarget, last.window == new.window, last.zone == new.zone { return }
        lastDropTarget = new
        dropTargetEnteredAt = Date()
    }

}
