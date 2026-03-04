//
//  WindowEventMonitor.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

// Unified C-compatible callback for all app-level AX notifications.
// Delivered on the main thread (run loop source added to main).
private func appNotificationCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    switch notification as String {
    case kAXWindowCreatedNotification as String:
        break
//        var pid: pid_t = 0
//        AXUIElementGetPid(element, &pid)
//        WindowSnapper.snapLeft(window: element, pid: pid)

    case kAXFocusedWindowChangedNotification as String,
         kAXMainWindowChangedNotification as String:
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return }
        WindowEventMonitor.shared.handleFocusChanged(axWindow: focusedRef as! AXUIElement)

    default:
        break
    }
}

final class WindowEventMonitor {
    static let shared = WindowEventMonitor()
    private init() {}

    /// AXObservers keyed by PID — one per app, handling window-created and focus-changed.
    /// All access is on the main thread.
    private var appObservers: [pid_t: AXObserver] = [:]

    func start() {
        guard AXIsProcessTrusted() else { return }

        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID else { continue }
            subscribe(pid: app.processIdentifier)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
        subscribe(pid: app.processIdentifier)
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return }
        handleFocusChanged(axWindow: focusedRef as! AXUIElement)
    }

    func handleFocusChanged(axWindow: AXUIElement) {
        guard !CurrentOffset.shared.isSuppressingFocusScroll else { return }
        guard let key = ResizeObserver.shared.elements.first(where: {
            CFEqual($0.value, axWindow)
        })?.key else { return }
        guard let slotIndex = ManagedSlotRegistry.shared.slotIndex(for: key) else { return }
        CurrentOffset.shared.scheduleOffsetUpdate(forSlot: slotIndex)
    }

    private func subscribe(pid: pid_t) {
        guard appObservers[pid] == nil else { return }

        var axObs: AXObserver?
        guard AXObserverCreate(pid, appNotificationCallback, &axObs) == .success,
              let axObs else { return }

        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(axObs, appElement, kAXWindowCreatedNotification as CFString, nil)
        AXObserverAddNotification(axObs, appElement, kAXFocusedWindowChangedNotification as CFString, nil)
        AXObserverAddNotification(axObs, appElement, kAXMainWindowChangedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObs), .commonModes)
        appObservers[pid] = axObs
    }
}
