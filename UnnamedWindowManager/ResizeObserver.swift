//
//  ResizeObserver.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

// `kAXUIElementDestroyedNotification` may not be bridged in all SDK versions.
private let kElementDestroyed = "AXUIElementDestroyed" as CFString

// C-compatible callback — must not capture any Swift context.
// refcon is Unmanaged<ResizeObserver> passed via AXObserverAddNotification.
private func axNotificationCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let obs = Unmanaged<ResizeObserver>.fromOpaque(refcon).takeUnretainedValue()
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    // Source is added to the main run loop — we are on the main thread.
    obs.handle(element: element, notification: notification as String, pid: pid)
}

final class ResizeObserver {
    static let shared = ResizeObserver()
    private init() {}

    // All mutable state is accessed only on the main thread.
    private var observers:  [pid_t: AXObserver]         = [:]
    private var elements:   [SnapKey: AXUIElement]      = [:]
    private var keysByPid:  [pid_t: Set<SnapKey>]       = [:]
    /// Keys whose reapply is in-flight; prevents re-entrancy from the resulting AX notification.
    private var reapplying: Set<SnapKey>                 = []
    /// Pending mouse-up poll work items, keyed by SnapKey.
    private var pendingReapply: [SnapKey: DispatchWorkItem] = [:]
    /// Translucent overlay shown over the current swap target while dragging.
    private var swapOverlay: NSWindow?

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

    private func updateSwapOverlay(for draggedKey: SnapKey, draggedWindow: AXUIElement) {
        guard let targetKey = WindowSnapper.findSwapTarget(for: draggedKey, window: draggedWindow),
              let targetElement = elements[targetKey],
              let axOrigin = WindowSnapper.readOrigin(of: targetElement),
              let axSize   = WindowSnapper.readSize(of: targetElement) else {
            hideSwapOverlay()
            return
        }

        // AX coordinates use a top-left origin; convert to AppKit's bottom-left origin.
        let screenHeight = NSScreen.screens[0].frame.height
        let appKitOrigin = CGPoint(x: axOrigin.x, y: screenHeight - axOrigin.y - axSize.height)
        let frame = CGRect(origin: appKitOrigin, size: axSize)
        let draggedWindowNumber = WindowSnapper.windowID(of: draggedWindow).map(Int.init)
        showSwapOverlay(frame: frame, belowWindow: draggedWindowNumber)
    }

    private func showSwapOverlay(frame: CGRect, belowWindow windowNumber: Int?) {
        if swapOverlay == nil {
            let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            win.isOpaque = false
            win.backgroundColor = .clear
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .transient]

            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = Config.overlayFillColor.cgColor
            view.layer?.borderColor = Config.overlayBorderColor.cgColor
            view.layer?.borderWidth = Config.overlayBorderWidth
            view.layer?.cornerRadius = Config.overlayCornerRadius
            win.contentView = view
            swapOverlay = win
        }
        swapOverlay?.setFrame(frame, display: false)
        if let windowNumber {
            swapOverlay?.order(.below, relativeTo: windowNumber)
        } else {
            swapOverlay?.orderFront(nil)
        }
    }

    private func hideSwapOverlay() {
        swapOverlay?.orderOut(nil)
    }

    private func axObserver(for pid: pid_t) -> AXObserver? {
        if let existing = observers[pid] { return existing }

        var axObs: AXObserver?
        let err = AXObserverCreate(pid, axNotificationCallback, &axObs)
        guard err == .success, let axObs else { return nil }
        observers[pid] = axObs
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        return axObs
    }

    /// Polls every 50 ms until no mouse button is held, then reapplies the snap.
    /// Any in-progress poll for the same key is cancelled before scheduling a new one.
    /// - Parameter isResize: true when triggered by a resize notification — accepts the
    ///   new size and reflows all snapped windows; false for move — restores position only.
    private func scheduleReapplyWhenMouseUp(key: SnapKey, isResize: Bool) {
        pendingReapply[key]?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReapply.removeValue(forKey: key)

            if NSEvent.pressedMouseButtons != 0 {
                self.scheduleReapplyWhenMouseUp(key: key, isResize: isResize)
                return
            }

            self.hideSwapOverlay()

            guard !self.reapplying.contains(key),
                  let storedElement = self.elements[key] else { return }

            if isResize {
                // Accept the new size, then reflow all snapped windows.
                if let newSize = WindowSnapper.readSize(of: storedElement) {
                    SnapRegistry.shared.setSize(width: newSize.width, height: newSize.height, for: key)
                }
                let allKeys = Set(SnapRegistry.shared.allEntries().map(\.key))
                self.reapplying.formUnion(allKeys)
                WindowSnapper.reapplyAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.reapplying.subtract(allKeys)
                }
            } else {
                // Check if the window was dropped on another snapped window's zone.
                if let targetKey = WindowSnapper.findSwapTarget(for: key, window: storedElement) {
                    SnapRegistry.shared.swapSlots(key, targetKey)
                    let allKeys = Set(SnapRegistry.shared.allEntries().map(\.key))
                    self.reapplying.formUnion(allKeys)
                    WindowSnapper.reapplyAll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.reapplying.subtract(allKeys)
                    }
                } else {
                    // Restore position (and stored size) of the moved window only.
                    self.reapplying.insert(key)
                    WindowSnapper.reapply(window: storedElement, key: key)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.reapplying.remove(key)
                    }
                }
            }
        }

        pendingReapply[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func cleanup(key: SnapKey, pid: pid_t) {
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
