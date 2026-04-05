import AppKit
import ApplicationServices

struct WindowCreatedEvent: AppEvent {
    let window: AXUIElement
    let pid: pid_t
    let appName: String
    let title: String
    let windowHash: UInt?
}
