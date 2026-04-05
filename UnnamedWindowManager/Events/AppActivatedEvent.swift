import AppKit

struct AppActivatedEvent: AppEvent {
    let app: NSRunningApplication
}
