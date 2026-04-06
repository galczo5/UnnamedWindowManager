import AppKit

// Registers global keyboard shortcuts by subscribing to KeyDownObserver.
// Parses config shortcuts into Bindings and matches incoming KeyDownEvents.
final class KeybindingService {
    static let shared = KeybindingService()

    private struct Binding {
        let label: String
        let modifiers: NSEvent.ModifierFlags
        /// Character match (for regular keys). Exactly one of key/keyCode is set.
        let key: String?
        /// Key code match (for arrow keys and other special keys).
        let keyCode: UInt16?
        let action: () -> Void
    }

    private var bindings: [Binding] = []
    private var subscriptionId: UUID?

    private init() {}

    func start() {
        guard AXIsProcessTrusted() else {
            Logger.shared.log("KeybindingService: Accessibility trust not granted — global shortcuts inactive")
            return
        }
        let all = makeBuiltInCandidates() + makeCommandCandidates()
        guard buildBindings(from: all) else { return }

        subscriptionId = KeyDownObserver.shared.subscribe { [weak self] event in
            guard let self else { return false }
            for binding in self.bindings {
                guard event.modifiers == binding.modifiers else { continue }
                if let keyCode = binding.keyCode {
                    guard event.keyCode == keyCode else { continue }
                } else if let key = binding.key {
                    guard event.characters == key else { continue }
                } else { continue }
                let action = binding.action
                DispatchQueue.main.async { action() }
                return true
            }
            return false
        }
    }

    private func makeBuiltInCandidates() -> [(String, String, () -> Void)] {
        [
            (Config.tileAllShortcut, "tileAll", {
                if TilingRootStore.shared.snapshotVisibleRoot() != nil {
                    UntileHandler.untileAll()
                } else if ScrollingRootStore.shared.snapshotVisibleScrollingRoot() != nil {
                    NotificationService.shared.post(title: "Cannot tile", body: "Unscroll all windows first.")
                } else {
                    TileAllHandler.tileAll()
                }
            }),
            (Config.tileShortcut, "tile", {
                if ScrollingRootStore.shared.snapshotVisibleScrollingRoot() != nil {
                    NotificationService.shared.post(title: "Cannot tile", body: "Unscroll all windows first.")
                    return
                }
                TileHandler.tileToggle()
            }),
            (Config.flipOrientationShortcut, "flipOrientation", { OrientFlipHandler.flipOrientation() }),
            (Config.focusLeftShortcut,       "focusLeft",       { FocusLeftHandler.focus() }),
            (Config.focusRightShortcut,      "focusRight",      { FocusRightHandler.focus() }),
            (Config.focusUpShortcut,         "focusUp",         { FocusUpHandler.focus() }),
            (Config.focusDownShortcut,       "focusDown",       { FocusDownHandler.focus() }),
            (Config.swapLeftShortcut,        "swapLeft",        { SwapLeftHandler.swap() }),
            (Config.swapRightShortcut,       "swapRight",       { SwapRightHandler.swap() }),
            (Config.swapUpShortcut,          "swapUp",          { SwapUpHandler.swap() }),
            (Config.swapDownShortcut,        "swapDown",        { SwapDownHandler.swap() }),
            (Config.scrollShortcut, "scroll", {
                if TilingRootStore.shared.snapshotVisibleRoot() != nil {
                    NotificationService.shared.post(title: "Cannot scroll", body: "Untile all windows first.")
                    return
                }
                ScrollHandler.scrollToggle()
            }),
            (Config.scrollAllShortcut, "scrollAll", {
                if ScrollingRootStore.shared.snapshotVisibleScrollingRoot() != nil {
                    UnscrollHandler.unscrollAll()
                } else if TilingRootStore.shared.snapshotVisibleRoot() != nil {
                    NotificationService.shared.post(title: "Cannot scroll", body: "Untile all windows first.")
                } else {
                    ScrollAllHandler.organizeScrolling()
                }
            }),
            (Config.toggleWallpaperShortcut, "toggleWallpaper", { WallpaperService.shared.toggle() }),
        ]
    }

    private func makeCommandCandidates() -> [(String, String, () -> Void)] {
        Config.commands.compactMap { cmd in
            guard let shortcut = cmd.shortcut, !shortcut.isEmpty,
                  let run = cmd.run, !run.isEmpty else { return nil }
            return (shortcut, "cmd:\(run)", { CommandService.execute(run) })
        }
    }

    /// Validates candidates for duplicate shortcuts and parses them into Bindings.
    /// Returns false if a duplicate was found or no bindings were configured.
    private func buildBindings(from candidates: [(String, String, () -> Void)]) -> Bool {
        let allShortcuts = candidates.compactMap { s, _, _ in s.isEmpty ? nil : s }
        if let duplicate = findDuplicate(allShortcuts) {
            NotificationService.shared.post(
                title: "Shortcut conflict",
                body: "Duplicate shortcut \"\(duplicate)\" — all shortcuts disabled. Fix in config."
            )
            Logger.shared.log("KeybindingService: duplicate shortcut '\(duplicate)' — all shortcuts disabled")
            bindings = []
            return false
        }

        bindings = []
        for (shortcut, label, action) in candidates {
            guard !shortcut.isEmpty, let parsed = parse(shortcut) else { continue }
            bindings.append(Binding(label: label, modifiers: parsed.modifiers, key: parsed.key, keyCode: parsed.keyCode, action: action))
        }

        guard !bindings.isEmpty else {
            return false
        }
        return true
    }

    func stop() {
        if let id = subscriptionId {
            KeyDownObserver.shared.unsubscribe(id: id)
            subscriptionId = nil
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
        let displayKey: String
        switch key {
        case "enter", "return": displayKey = "↩"
        case "left":            displayKey = "←"
        case "right":           displayKey = "→"
        case "up":              displayKey = "↑"
        case "down":            displayKey = "↓"
        default:                displayKey = key
        }
        return modifiers + displayKey
    }

    private struct ParsedBinding {
        let modifiers: NSEvent.ModifierFlags
        let key: String?
        let keyCode: UInt16?
    }

    /// Returns the first shortcut string that appears more than once (after normalization), or nil.
    private func findDuplicate(_ shortcuts: [String]) -> String? {
        var seen: Set<String> = []
        for shortcut in shortcuts {
            let normalized = normalize(shortcut)
            if !seen.insert(normalized).inserted { return shortcut }
        }
        return nil
    }

    /// Normalizes a shortcut string for duplicate comparison: lowercase, canonical modifier names, sorted modifiers.
    private func normalize(_ shortcut: String) -> String {
        let tokens = shortcut.lowercased().split(separator: "+").map(String.init)
        guard tokens.count >= 2 else { return shortcut.lowercased() }
        let key = tokens.last!
        let mods = tokens.dropLast().map { token -> String in
            switch token {
            case "command":            return "cmd"
            case "control":            return "ctrl"
            case "alt", "option":      return "opt"
            case "enter":              return "return"
            default:                   return token
            }
        }.sorted()
        let normalizedKey = key == "enter" ? "return" : key
        return (mods + [normalizedKey]).joined(separator: "+")
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
        case "left":           return ParsedBinding(modifiers: modifiers, key: nil, keyCode: 123)
        case "right":          return ParsedBinding(modifiers: modifiers, key: nil, keyCode: 124)
        case "down":           return ParsedBinding(modifiers: modifiers, key: nil, keyCode: 125)
        case "up":             return ParsedBinding(modifiers: modifiers, key: nil, keyCode: 126)
        case "enter", "return": return ParsedBinding(modifiers: modifiers, key: nil, keyCode: 36)
        case "space":          return ParsedBinding(modifiers: modifiers, key: nil, keyCode: 49)
        case "tab":            return ParsedBinding(modifiers: modifiers, key: nil, keyCode: 48)
        default:               return ParsedBinding(modifiers: modifiers, key: rawKey, keyCode: nil)
        }
    }
}
