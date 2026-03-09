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
            Logger.shared.log("Config: created default config at \(filePath)")
            return ConfigData.defaults
        }

        guard let contents = fm.contents(atPath: filePath),
              let yaml = String(data: contents, encoding: .utf8) else {
            Logger.shared.log("Config: could not read \(filePath), using defaults")
            return ConfigData.defaults
        }

        do {
            let parsed = try YAMLDecoder().decode(ConfigData.self, from: yaml)
            for key in parsed.missingKeys {
                Logger.shared.log("Config: missing '\(key)', using default")
            }
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
        let l  = s?.layout    ?? d.layout!
        let dz = s?.dropZones ?? d.dropZones!
        let ov = s?.overlay   ?? d.overlay!
        let bh = s?.behavior  ?? d.behavior!
        let sh = s?.shortcuts ?? d.shortcuts!

        func num(_ v: CGFloat?) -> String {
            guard let v = v else { return "null" }
            return v == CGFloat(Int(v)) ? String(Int(v)) : String(Double(v))
        }

        return """
        config:
          layout:
            # Gap between snapped windows and screen edges (points).
            gap: \(num(l.gap))
            # Fallback width fraction of the visible screen when a window's size cannot be read.
            fallbackWidthFraction: \(num(l.fallbackWidthFraction))
            # Maximum width of a snapped window as a fraction of the visible screen width.
            maxWidthFraction: \(num(l.maxWidthFraction))
            # Maximum height of a snapped window as a fraction of the visible screen height.
            maxHeightFraction: \(num(l.maxHeightFraction))
          dropZones:
            # Fraction of a window's width that counts as the left drop zone.
            leftFraction: \(num(dz.leftFraction))
            # Fraction of a window's width that counts as the right drop zone.
            rightFraction: \(num(dz.rightFraction))
            # Fraction of a slot's height (from the bottom) that activates the bottom drop zone.
            bottomFraction: \(num(dz.bottomFraction))
            # Fraction of a slot's height (from the top) that activates the top drop zone.
            topFraction: \(num(dz.topFraction))
          overlay:
            # Corner radius of the swap-target overlay rectangle (points).
            cornerRadius: \(num(ov.cornerRadius))
            # Border width of the swap-target overlay rectangle (points).
            borderWidth: \(num(ov.borderWidth))
            # Accent color of the drop-zone overlay (black, white, blue, red, green, orange, yellow, pink, purple, teal, indigo, brown, mint, cyan, gray).
            overlayColor: \(ov.overlayColor ?? "blue")
          behavior:
            # Automatically snap new windows into the layout when at least one snapped window is visible.
            autoSnap: \(bh.autoSnap ?? false)
            # Automatically snap the first window on an empty screen (bootstrap when no layout exists).
            autoOrganize: \(bh.autoOrganize ?? false)
            # Time in seconds a window must hover over a drop zone before the operation is allowed (0 to disable).
            dropZoneHoverDelay: \(num(bh.dropZoneHoverDelay))
            # Dim non-focused managed windows when a layout is active.
            dimInactiveWindows: \(bh.dimInactiveWindows ?? true)
            # Opacity of non-focused managed windows (0.0–1.0). Only used when dimInactiveWindows is true.
            dimInactiveOpacity: \(num(bh.dimInactiveOpacity))
            # Duration in seconds of the dim overlay fade-in and fade-out animation (0 to disable).
            dimAnimationDuration: \(num(bh.dimAnimationDuration))
            # Color of the dim overlay (black, white, blue, red, green, orange, yellow, pink, purple, teal, indigo, brown, mint, cyan, gray).
            dimColor: \(bh.dimColor ?? "black")
          shortcuts:
            # Global keyboard shortcut for Snap All / Unsnap All toggle. Format: modifier+key (e.g. cmd+', cmd+shift+o). Empty string disables.
            snapAll: "\(sh.snapAll ?? "cmd+'")"
            # Global keyboard shortcut for Snap. Empty string disables.
            snap: "\(sh.snap ?? "")"
            # Global keyboard shortcut for Unsnap. Empty string disables.
            unsnap: "\(sh.unsnap ?? "")"
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
        """
    }
}
