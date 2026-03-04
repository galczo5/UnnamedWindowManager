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
    var observers:  [pid_t: AXObserver]                  = [:]
    var elements:   [ManagedWindow: AXUIElement]          = [:]
    var keysByPid:  [pid_t: Set<ManagedWindow>]           = [:]
    /// Keys whose reapply is in-flight; prevents re-entrancy from the resulting AX notification.
    var reapplying: Set<ManagedWindow>                    = []
    /// Pending mouse-up poll work items, keyed by ManagedWindow.
    var pendingReapply: [ManagedWindow: DispatchWorkItem] = [:]
    /// Translucent overlay shown over the current swap target while dragging.
    var swapOverlay: NSWindow?

    // MARK: – Public

    func observe(window: AXUIElement, pid: pid_t, key: ManagedWindow) {
        guard elements[key] == nil else { return }

        elements[key] = window
        keysByPid[pid, default: []].insert(key)

        guard let axObs = axObserver(for: pid) else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(axObs, window, kAXWindowMovedNotification   as CFString, refcon)
        AXObserverAddNotification(axObs, window, kAXWindowResizedNotification as CFString, refcon)
        AXObserverAddNotification(axObs, window, kElementDestroyed,                        refcon)
    }

    func stopObserving(key: ManagedWindow, pid: pid_t) {
        guard let window = elements[key], let axObs = observers[pid] else { return }
        AXObserverRemoveNotification(axObs, window, kAXWindowMovedNotification   as CFString)
        AXObserverRemoveNotification(axObs, window, kAXWindowResizedNotification as CFString)
        AXObserverRemoveNotification(axObs, window, kElementDestroyed)
        cleanup(key: key, pid: pid)
    }

    func window(for key: ManagedWindow) -> AXUIElement? {
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
                ManagedSlotRegistry.shared.removeAndReflow(key, screen: screen)
            } else {
                ManagedSlotRegistry.shared.remove(key)
            }
            cleanup(key: key, pid: pid)
            WindowVisibilityManager.shared.windowRemoved(key)
            WindowSnapper.reapplyAll()
            return
        }

        guard ManagedSlotRegistry.shared.isTracked(key) else { return }
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

    func cleanup(key: ManagedWindow, pid: pid_t) {
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
