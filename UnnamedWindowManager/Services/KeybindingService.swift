import AppKit
import ApplicationServices

// Registers global keyboard shortcuts and dispatches actions when they fire.
final class KeybindingService {
    static let shared = KeybindingService()

    private var monitor: Any?

    private init() {}

    func start() {
        guard AXIsProcessTrusted() else {
            Logger.shared.log("KeybindingService: Accessibility trust not granted — global shortcuts inactive")
            return
        }
        guard let (modifiers, key) = parse(Config.organizeShortcut) else {
            Logger.shared.log("KeybindingService: could not parse shortcut '\(Config.organizeShortcut)'")
            return
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == modifiers,
                  event.charactersIgnoringModifiers == key else { return }
            DispatchQueue.main.async { OrganizeHandler.organize() }
        }
        Logger.shared.log("KeybindingService: registered organize shortcut '\(Config.organizeShortcut)'")
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
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
