import AppKit

struct WindowDestroyedEvent: AppEvent {
    let key: WindowSlot
    let pid: pid_t
}
