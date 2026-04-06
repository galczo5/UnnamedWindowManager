import ApplicationServices

struct WindowMovedEvent: AppEvent {
    let key: WindowSlot
    let element: AXUIElement
    let pid: pid_t
}
