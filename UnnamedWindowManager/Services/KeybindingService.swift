import CoreGraphics
import AppKit
import ApplicationServices

// Registers global keyboard shortcuts via a CGEventTap, consuming matched events.
final class KeybindingService {
    static let shared = KeybindingService()

    private struct Binding {
        let modifiers: NSEvent.ModifierFlags
        /// Character match (for regular keys). Exactly one of key/keyCode is set.
        let key: String?
        /// Key code match (for arrow keys and other special keys).
        let keyCode: UInt16?
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
            (Config.focusLeftShortcut,       { FocusLeftHandler.focus() }),
            (Config.focusRightShortcut,      { FocusRightHandler.focus() }),
            (Config.focusUpShortcut,         { FocusUpHandler.focus() }),
            (Config.focusDownShortcut,       { FocusDownHandler.focus() }),
        ]

        bindings = []
        for (shortcut, action) in candidates {
            guard !shortcut.isEmpty, let parsed = parse(shortcut) else { continue }
            bindings.append(Binding(modifiers: parsed.modifiers, key: parsed.key, keyCode: parsed.keyCode, action: action))
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
                let flags = nsEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
                for binding in service.bindings {
                    guard flags == binding.modifiers else { continue }
                    if let keyCode = binding.keyCode {
                        guard nsEvent.keyCode == keyCode else { continue }
                    } else if let key = binding.key {
                        guard nsEvent.charactersIgnoringModifiers == key else { continue }
                    } else { continue }
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

    private struct ParsedBinding {
        let modifiers: NSEvent.ModifierFlags
        let key: String?
        let keyCode: UInt16?
    }

    /// Parses a shortcut string like "cmd+'" into modifier flags and a key or keyCode.
    /// Arrow key names ("left", "right", "up", "down") are matched by keyCode for reliability with modifier combos.
    private func parse(_ shortcut: String) -> ParsedBinding? {
        let tokens = shortcut.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count >= 2 else { return nil }
        let rawKey = tokens.last!
        guard !rawKey.isEmpty else { return nil }
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
        switch rawKey {
        case "left":  return ParsedBinding(modifiers: modifiers, key: nil, keyCode: 123)
        case "right": return ParsedBinding(modifiers: modifiers, key: nil, keyCode: 124)
        case "down":  return ParsedBinding(modifiers: modifiers, key: nil, keyCode: 125)
        case "up":    return ParsedBinding(modifiers: modifiers, key: nil, keyCode: 126)
        default:      return ParsedBinding(modifiers: modifiers, key: rawKey, keyCode: nil)
        }
    }
}
