import AppKit

struct WindowTitleChangedEvent: AppEvent {
    let key: WindowSlot
    let pid: pid_t
}
