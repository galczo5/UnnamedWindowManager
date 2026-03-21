import ApplicationServices

// C-compatible callback — must not capture any Swift context.
// refcon is Unmanaged<ResizeObserver> passed via AXObserverAddNotification.
func axNotificationCallback(
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
