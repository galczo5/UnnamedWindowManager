import AppKit

struct FocusedWindowChangedEvent: AppEvent {
    let pid: pid_t
}
