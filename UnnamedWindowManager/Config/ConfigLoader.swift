import Foundation
import Yams

// Reads and writes ~/.config/unnamed/config.yml, creating it from defaults when absent.
struct ConfigLoader {
    static let directoryPath = NSHomeDirectory() + "/.config/unnamed"
    static let filePath = directoryPath + "/config.yml"

    /// Loads config from disk. Creates the file from defaults if it does not exist.
    static func load() -> ConfigData {
        let fm = FileManager.default

        if !fm.fileExists(atPath: directoryPath) {
            try? fm.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        }

        if !fm.fileExists(atPath: filePath) {
            write(ConfigData.defaults)
            return ConfigData.defaults
        }

        guard let contents = fm.contents(atPath: filePath),
              let yaml = String(data: contents, encoding: .utf8) else {
            Logger.shared.log("Config: could not read \(filePath), using defaults")
            return ConfigData.defaults
        }

        do {
            let parsed = try YAMLDecoder().decode(ConfigData.self, from: yaml)
            return parsed.mergedWithDefaults()
        } catch {
            Logger.shared.log("Config: parse error — \(error.localizedDescription), using defaults")
            return ConfigData.defaults
        }
    }

    static func write(_ data: ConfigData) {
        let yaml = format(data)
        do {
            try yaml.write(toFile: filePath, atomically: true, encoding: .utf8)
        } catch {
            Logger.shared.log("Config: failed to write config — \(error.localizedDescription)")
        }
    }

    private static func format(_ data: ConfigData) -> String {
        let d = ConfigData.defaults.config!
        let s = data.config
        let l  = s?.layout     ?? d.layout!
        let og = l.outerGaps  ?? d.layout!.outerGaps!
        let ov = s?.overlay   ?? d.overlay!
        let fb = s?.focusedBorder ?? d.focusedBorder!
        let bh = s?.behavior  ?? d.behavior!
        let wp = s?.wallpaper ?? d.wallpaper!
        let am = s?.autoMode  ?? d.autoMode!
        let sh = s?.shortcuts ?? d.shortcuts!
        let cm = s?.commands ?? d.commands ?? []

        let commandLines = cm.map { c in
            "    - shortcut: \"\(c.shortcut ?? "")\"\n      run: \"\(c.run ?? "")\""
        }.joined(separator: "\n")

        func num(_ v: CGFloat?) -> String {
            guard let v = v else { return "null" }
            return v == CGFloat(Int(v)) ? String(Int(v)) : String(Double(v))
        }

        return """
        config:
          layout:
            # Gap between adjacent snapped windows (points).
            innerGap: \(num(l.innerGap))
            # Gaps between outermost windows and screen edges (points).
            outerGaps:
              left: \(num(og.left))
              top: \(num(og.top))
              right: \(num(og.right))
              bottom: \(num(og.bottom))
          overlay:
            # Accent color of the drop-zone overlay (black, white, blue, red, green, orange, yellow, pink, purple, teal, indigo, brown, mint, cyan, gray).
            overlayColor: \(ov.overlayColor ?? "blue")
          focusedBorder:
            # Color of the focused-window border ring (black, white, blue, red, green, orange, yellow, pink, purple, teal, indigo, brown, mint, cyan, gray).
            color: \(fb.color ?? "white")
            # Width of the focused-window border ring in points.
            width: \(num(fb.width))
          behavior:
            # Time in seconds a window must hover over a drop zone before the operation is allowed (0 to disable).
            dropZoneHoverDelay: \(num(bh.dropZoneHoverDelay))
            # Dim non-focused managed windows when a layout is active.
            dimInactiveWindows: \(bh.dimInactiveWindows ?? true)
            # Opacity of non-focused managed windows (0.0–1.0). Only used when dimInactiveWindows is true.
            dimInactiveOpacity: \(num(bh.dimInactiveOpacity))
            # Duration in seconds of the dim overlay fade-in and fade-out animation (0 to disable).
            dimAnimationDuration: \(num(bh.dimAnimationDuration))
            # Duration in seconds for window move/resize animation (0 to disable).
            animationDuration: \(num(bh.animationDuration))
            # Color of the dim overlay (black, white, blue, red, green, orange, yellow, pink, purple, teal, indigo, brown, mint, cyan, gray).
            dimColor: \(bh.dimColor ?? "black")
            # Path to log file. Leave empty or omit to disable logging.
            logPath: "\(bh.logPath ?? "")"
          wallpaper:
            # Enable custom wallpaper overlay.
            enabled: \(wp.enabled ?? false)
            # Path to image file (PNG, JPG, or GIF). Supports ~ for home directory.
            path: "\(wp.path ?? "")"
            # Image scaling mode: fill, fit, stretch, or center.
            scaling: \(wp.scaling ?? "fill")
          autoMode:
            # Global keyboard shortcut to toggle auto mode on/off. Empty string disables.
            keybinding: "\(am.keybinding ?? "")"
            # Enable auto mode automatically when the app starts.
            enabledOnStart: \(am.enabledOnStart ?? false)
          shortcuts:
            # Global keyboard shortcut for Tile All / Untile All toggle. Format: modifier+key (e.g. cmd+', cmd+shift+o). Empty string disables.
            tileAll: "\(sh.tileAll ?? "cmd+'")"
            # Global keyboard shortcut for Tile / Untile toggle (tiles if not tiled, untiles if tiled). Empty string disables.
            tile: "\(sh.tile ?? "")"
            # Global keyboard shortcut for Reset Layout. Empty string disables.
            resetLayout: "\(sh.resetLayout ?? "")"
            # Global keyboard shortcut for Refresh. Empty string disables.
            refresh: "\(sh.refresh ?? "")"
            # Global keyboard shortcut for Flip Orientation. Empty string disables.
            flipOrientation: "\(sh.flipOrientation ?? "")"
            # Global keyboard shortcuts for focusing the nearest snapped window in a direction.
            focusLeft: "\(sh.focusLeft ?? "ctrl+opt+left")"
            focusRight: "\(sh.focusRight ?? "ctrl+opt+right")"
            focusUp: "\(sh.focusUp ?? "ctrl+opt+up")"
            focusDown: "\(sh.focusDown ?? "ctrl+opt+down")"
            # Global keyboard shortcuts for swapping the focused window with its directional neighbour.
            swapLeft: "\(sh.swapLeft ?? "ctrl+shift+left")"
            swapRight: "\(sh.swapRight ?? "ctrl+shift+right")"
            swapUp: "\(sh.swapUp ?? "ctrl+shift+up")"
            swapDown: "\(sh.swapDown ?? "ctrl+shift+down")"
            # Global keyboard shortcut for toggling scroll mode on a single window.
            scroll: "\(sh.scroll ?? "cmd+[")"
            # Global keyboard shortcut for Scroll All / Unscroll All toggle.
            scrollAll: "\(sh.scrollAll ?? "cmd+]")"
            # Global keyboard shortcut for toggling wallpaper on/off. Empty string disables.
            toggleWallpaper: "\(sh.toggleWallpaper ?? "")"
          # Custom keyboard shortcuts that run shell commands.
          # Format: shortcut uses modifier+key (e.g. cmd+enter, cmd+shift+t). run is a shell command.
          commands:
        \(commandLines)
        """
    }
}
