import AppKit

struct AppTerminatedEvent: AppEvent {
    let app: NSRunningApplication
}
