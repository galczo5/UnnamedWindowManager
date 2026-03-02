//
//  ResizeObserver.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

// `kAXUIElementDestroyedNotification` may not be bridged in all SDK versions.
private let kElementDestroyed = "AXUIElementDestroyed" as CFString

final class ResizeObserver {
    static let shared = ResizeObserver()
    private init() {}

    // All mutable state is accessed only on the main thread.
    var observers:  [pid_t: AXObserver]             = [:]
    var elements:   [SnapKey: AXUIElement]           = [:]
    var keysByPid:  [pid_t: Set<SnapKey>]            = [:]
    /// Keys whose reapply is in-flight; prevents re-entrancy from the resulting AX notification.
    var reapplying: Set<SnapKey>                     = []
    /// Pending mouse-up poll work items, keyed by SnapKey.
    var pendingReapply: [SnapKey: DispatchWorkItem]  = [:]
    /// Translucent overlay shown over the current swap target while dragging.
    var swapOverlay: NSWindow?

    // MARK: – Public

    func observe(window: AXUIElement, pid: pid_t, key: SnapKey) {
        guard elements[key] == nil else { return }

        elements[key] = window
        keysByPid[pid, default: []].insert(key)

        guard let axObs = axObserver(for: pid) else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(axObs, window, kAXWindowMovedNotification   as CFString, refcon)
        AXObserverAddNotification(axObs, window, kAXWindowResizedNotification as CFString, refcon)
        AXObserverAddNotification(axObs, window, kElementDestroyed,                        refcon)
    }

    func stopObserving(key: SnapKey, pid: pid_t) {
        guard let window = elements[key], let axObs = observers[pid] else { return }
        AXObserverRemoveNotification(axObs, window, kAXWindowMovedNotification   as CFString)
        AXObserverRemoveNotification(axObs, window, kAXWindowResizedNotification as CFString)
        AXObserverRemoveNotification(axObs, window, kElementDestroyed)
        cleanup(key: key, pid: pid)
    }

    func window(for key: SnapKey) -> AXUIElement? {
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

        if notification == kElementDestroyed as String {
            SnapRegistry.shared.remove(key)
            cleanup(key: key, pid: pid)
            return
        }

        guard SnapRegistry.shared.isTracked(key) else { return }
        guard !reapplying.contains(key) else { return }

        let isResize = notification == (kAXWindowResizedNotification as String)

        // While a drag is in progress, update the swap-target overlay in real time.
        if !isResize && NSEvent.pressedMouseButtons != 0 {
            updateSwapOverlay(for: key, draggedWindow: element)
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

    func cleanup(key: SnapKey, pid: pid_t) {
        pendingReapply[key]?.cancel()
        pendingReapply.removeValue(forKey: key)
        hideSwapOverlay()
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
}
