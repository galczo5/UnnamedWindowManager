import AppKit
import CoreGraphics
import ApplicationServices

// Captures global keyboard events via CGEventTap and fires KeyDownEvent.
// Modifier flags (.numericPad, .function) are stripped before the event is dispatched.
// Uses ConsumingEventObserver: the first subscriber returning true consumes the event (returns nil to the tap).
final class KeyDownObserver: ConsumingEventObserver<KeyDownEvent> {
    static let shared = KeyDownObserver()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private override init() {}

    func start() {
        guard AXIsProcessTrusted() else { return }
        installEventTap()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
    }

    private func installEventTap() {
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let refcon,
                       let tap = Unmanaged<KeyDownObserver>.fromOpaque(refcon).takeUnretainedValue().eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passRetained(event)
                }
                guard let refcon, type == .keyDown else {
                    return Unmanaged.passRetained(event)
                }
                let observer = Unmanaged<KeyDownObserver>.fromOpaque(refcon).takeUnretainedValue()
                guard let nsEvent = NSEvent(cgEvent: event) else {
                    return Unmanaged.passRetained(event)
                }
                let flags = nsEvent.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting([.numericPad, .function])
                let keyEvent = KeyDownEvent(
                    keyCode: nsEvent.keyCode,
                    characters: nsEvent.charactersIgnoringModifiers,
                    modifiers: flags
                )
                if observer.notify(keyEvent) { return nil }
                return Unmanaged.passRetained(event)
            },
            userInfo: userInfo
        ) else {
            Logger.shared.log("KeyDownObserver: failed to create event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
    }
}
