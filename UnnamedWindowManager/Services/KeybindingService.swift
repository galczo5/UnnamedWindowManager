import CoreGraphics
import AppKit
import ApplicationServices

// Registers global keyboard shortcuts via a CGEventTap, consuming matched events.
final class KeybindingService {
    static let shared = KeybindingService()

    private struct Binding {
        let modifiers: NSEvent.ModifierFlags
        let key: String
        let action: () -> Void
    }

    private var bindings: [Binding] = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    func start() {
        guard AXIsProcessTrusted() else {
            Logger.shared.log("KeybindingService: Accessibility trust not granted — global shortcuts inactive")
            return
        }

        let candidates: [(String, () -> Void)] = [
            (Config.organizeShortcut,        { OrganizeHandler.organize() }),
            (Config.snapShortcut,            { SnapHandler.snap() }),
            (Config.unsnapShortcut,          { UnsnapHandler.unsnap() }),
            (Config.unsnapAllShortcut,       { UnsnapHandler.unsnapAll() }),
            (Config.flipOrientationShortcut, { OrientFlipHandler.flipOrientation() }),
        ]

        bindings = []
        for (shortcut, action) in candidates {
            guard !shortcut.isEmpty, let (mods, key) = parse(shortcut) else { continue }
            bindings.append(Binding(modifiers: mods, key: key, action: action))
        }

        guard !bindings.isEmpty else {
            Logger.shared.log("KeybindingService: no shortcuts configured")
            return
        }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon, type == .keyDown else {
                    return Unmanaged.passRetained(event)
                }
                let service = Unmanaged<KeybindingService>.fromOpaque(refcon).takeUnretainedValue()
                guard let nsEvent = NSEvent(cgEvent: event) else {
                    return Unmanaged.passRetained(event)
                }
                let flags = nsEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                for binding in service.bindings {
                    guard flags == binding.modifiers,
                          nsEvent.charactersIgnoringModifiers == binding.key else { continue }
                    let action = binding.action
                    DispatchQueue.main.async { action() }
                    return nil // consume the event
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: userInfo
        ) else {
            Logger.shared.log("KeybindingService: failed to create event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        Logger.shared.log("KeybindingService: registered \(bindings.count) shortcut(s)")
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
        bindings = []
    }

    func restart() {
        stop()
        start()
    }

    /// Formats a shortcut string like "cmd+'" into a display label like "⌘'".
    static func displayString(_ shortcut: String) -> String {
        let tokens = shortcut.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count >= 2 else { return shortcut }
        let key = tokens.last!
        let modifiers = tokens.dropLast().map { token -> String in
            switch token {
            case "cmd", "command": return "⌘"
            case "shift":          return "⇧"
            case "ctrl", "control": return "⌃"
            case "alt", "opt", "option": return "⌥"
            default: return token
            }
        }.joined()
        return modifiers + key
    }

    /// Parses a shortcut string like "cmd+'" into modifier flags and a key character.
    private func parse(_ shortcut: String) -> (NSEvent.ModifierFlags, String)? {
        let tokens = shortcut.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count >= 2 else { return nil }
        let key = tokens.last!
        guard !key.isEmpty else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for token in tokens.dropLast() {
            switch token {
            case "cmd", "command": modifiers.insert(.command)
            case "shift":          modifiers.insert(.shift)
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "opt", "option": modifiers.insert(.option)
            default:
                Logger.shared.log("KeybindingService: unknown modifier '\(token)' in shortcut '\(shortcut)'")
                return nil
            }
        }
        return (modifiers, key)
    }
}
