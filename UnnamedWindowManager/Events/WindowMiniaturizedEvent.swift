import AppKit

struct WindowMiniaturizedEvent: AppEvent {
    let key: WindowSlot
    let pid: pid_t
}
