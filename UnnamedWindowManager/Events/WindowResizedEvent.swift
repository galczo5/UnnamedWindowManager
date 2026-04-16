import ApplicationServices

struct WindowResizedEvent: AppEvent {
    let key: WindowSlot
    let element: AXUIElement
    let pid: pid_t
    let isFullScreen: Bool
}
