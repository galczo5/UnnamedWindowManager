import AppKit
import ApplicationServices

// `kAXUIElementDestroyedNotification` may not be bridged in all SDK versions.
private let kElementDestroyed = "AXUIElementDestroyed" as CFString

// Tracks AX move/resize/destroy notifications for all snapped windows and drives layout reapplication.
final class ResizeObserver {
    static let shared = ResizeObserver()
    private init() {}

    // All mutable state is accessed only on the main thread.
    var observers:  [pid_t: AXObserver]                  = [:]
    var elements:   [WindowSlot: AXUIElement]             = [:]
    var keysByPid:  [pid_t: Set<WindowSlot>]              = [:]
    /// Keys whose reapply is in-flight; prevents re-entrancy from the resulting AX notification.
    var reapplying: Set<WindowSlot>                       = []
    var pendingReapply: [WindowSlot: DispatchWorkItem]    = [:]
    let overlay = SwapOverlay()

    private var lastDropTarget: DropTarget?
    private var dropTargetEnteredAt: Date?

    // MARK: – Public

    func observe(window: AXUIElement, pid: pid_t, key: WindowSlot) {
        guard elements[key] == nil else { return }

        elements[key] = window
        keysByPid[pid, default: []].insert(key)

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
        // Use CFEqual to find the stored key — avoids relying on CF pointer identity
        // across API boundaries (the callback element may be a distinct Swift wrapper
        // around the same underlying AXUIElementRef).
        guard let key = keysByPid[pid]?.first(where: {
            elements[$0].map { CFEqual($0, element) } == true
        }) else { return }

        let eventLabel = notification == (kAXWindowResizedNotification as String) ? "resize" : "move"
        Logger.shared.log("[\(eventLabel)] key=\(key.windowHash) pid=\(pid)")

        if notification == kElementDestroyed as String {
            if let screen = NSScreen.main {
                SnapService.shared.removeAndReflow(key, screen: screen)
            } else {
                SnapService.shared.remove(key)
            }
            cleanup(key: key, pid: pid)
            WindowVisibilityManager.shared.windowRemoved(key)
            ReapplyHandler.reapplyAll()
            return
        }

        guard SnapService.shared.isTracked(key) else { return }
        guard !reapplying.contains(key) else { return }

        let isResize = notification == (kAXWindowResizedNotification as String)

        // While a drag is in progress, update the drop-zone overlay in real time.
        if !isResize && NSEvent.pressedMouseButtons != 0 {
            let drop = ReapplyHandler.findDropTarget(forKey: key)
            updateTrackedDropTarget(drop)
            overlay.update(dropTarget: drop, draggedWindow: element, elements: elements)
        }

        scheduleReapplyWhenMouseUp(key: key, isResize: isResize)
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
        reapplying.remove(key)
        keysByPid[pid]?.remove(key)

        if keysByPid[pid]?.isEmpty == true {
            if let axObs = observers[pid] {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
            }
            observers.removeValue(forKey: pid)
            keysByPid.removeValue(forKey: pid)
        }
    }

    // MARK: - Reapply

    /// Polls every 50 ms until no mouse button is held, then reapplies the snap.
    /// Any in-progress poll for the same key is cancelled before scheduling a new one.
    /// - Parameter isResize: true when triggered by a resize notification — accepts the
    ///   new size and reflows all snapped windows; false for move — restores position only.
    func scheduleReapplyWhenMouseUp(key: WindowSlot, isResize: Bool) {
        pendingReapply[key]?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReapply.removeValue(forKey: key)

            if NSEvent.pressedMouseButtons != 0 {
                self.scheduleReapplyWhenMouseUp(key: key, isResize: isResize)
                return
            }

            self.overlay.hide()
            let hoverStart = self.dropTargetEnteredAt
            self.lastDropTarget = nil
            self.dropTargetEnteredAt = nil

            guard !self.reapplying.contains(key),
                  let storedElement = self.elements[key] else { return }

            if isResize {
                guard let screen = NSScreen.main,
                      let axElement = self.elements[key],
                      let actualSize = readSize(of: axElement) else { return }

                let allWindows = self.allTrackedWindows()
                self.reapplying.formUnion(allWindows)
                SnapService.shared.resize(key: key, actualSize: actualSize, screen: screen)
                ReapplyHandler.reapplyAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.reapplying.subtract(allWindows)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let screen = NSScreen.main else { return }
                    PostResizeValidator.checkAndFixRefusals(windows: allWindows, screen: screen)
                }
            } else {
                // Move: directional insert, center swap, or restore.
                let hoverDuration = hoverStart.map { Date().timeIntervalSince($0) } ?? 0
                let dropAllowed = hoverDuration >= Config.dropZoneHoverDelay
                if dropAllowed, let drop = ReapplyHandler.findDropTarget(forKey: key) {
                    let allWindows = self.allTrackedWindows()
                    self.reapplying.formUnion(allWindows)
                    if drop.zone == .center {
                        SnapService.shared.swap(key, drop.window)
                    } else if let screen = NSScreen.main {
                        SnapService.shared.insertAdjacent(dragged: key, target: drop.window,
                                                          zone: drop.zone, screen: screen)
                    }
                    ReapplyHandler.reapplyAll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.reapplying.subtract(allWindows)
                    }
                } else {
                    self.reapplying.insert(key)
                    ReapplyHandler.reapply(window: storedElement, key: key)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.reapplying.remove(key)
                    }
                }
            }
        }

        pendingReapply[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
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

    private func allTrackedWindows() -> Set<WindowSlot> {
        let leaves = SnapService.shared.leavesInVisibleRoot()
        return Set(leaves.compactMap { leaf -> WindowSlot? in
            if case .window(let w) = leaf { return w }
            return nil
        })
    }
}
