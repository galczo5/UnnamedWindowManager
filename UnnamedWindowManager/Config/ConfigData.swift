import CoreGraphics

// Decoded representation of config.yml. All fields optional to allow partial files.
struct ConfigData: Codable {
    var config: ConfigSection?

    struct ConfigSection: Codable {
        var layout: LayoutConfig?
        var dropZones: DropZoneConfig?
        var overlay: OverlayConfig?
        var behavior: BehaviorConfig?
        var wallpaper: WallpaperConfig?
        var shortcuts: ShortcutsConfig?
        var commands: [CommandConfig]?
    }

    struct OuterGapsConfig: Codable {
        var left: CGFloat?
        var top: CGFloat?
        var right: CGFloat?
        var bottom: CGFloat?
    }

    struct LayoutConfig: Codable {
        var innerGap: CGFloat?
        var outerGaps: OuterGapsConfig?
        var fallbackWidthFraction: CGFloat?
        var maxWidthFraction: CGFloat?
        var maxHeightFraction: CGFloat?
        var scrollCenterDefaultWidthFraction: CGFloat?
    }

    struct DropZoneConfig: Codable {
        var leftFraction: CGFloat?
        var rightFraction: CGFloat?
        var bottomFraction: CGFloat?
        var topFraction: CGFloat?
    }

    struct OverlayConfig: Codable {
        var cornerRadius: CGFloat?
        var borderWidth: CGFloat?
        var overlayColor: String?
    }

    struct BehaviorConfig: Codable {
        var dropZoneHoverDelay: CGFloat?
        var dimInactiveWindows: Bool?
        var dimInactiveOpacity: CGFloat?
        var dimAnimationDuration: CGFloat?
        var animationDuration: CGFloat?
        var dimColor: String?
        var logPath: String?
    }

    struct WallpaperConfig: Codable {
        var enabled: Bool?
        var path: String?
        var scaling: String?
    }

    struct CommandConfig: Codable {
        var shortcut: String?
        var run: String?
    }

    struct ShortcutsConfig: Codable {
        var tileAll: String?
        var tile: String?
        var resetLayout: String?
        var refresh: String?
        var flipOrientation: String?
        var focusLeft: String?
        var focusRight: String?
        var focusUp: String?
        var focusDown: String?
        var scroll: String?
        var scrollAll: String?
        var swapLeft: String?
        var swapRight: String?
        var swapUp: String?
        var swapDown: String?
        var toggleWallpaper: String?
    }

    static let defaults = ConfigData(config: ConfigSection(
        layout: LayoutConfig(innerGap: 5, outerGaps: OuterGapsConfig(left: 20, top: 5, right: 20, bottom: 5), fallbackWidthFraction: 0.4, maxWidthFraction: 0.80, maxHeightFraction: 1.0, scrollCenterDefaultWidthFraction: 0.9),
        dropZones: DropZoneConfig(leftFraction: 0.20, rightFraction: 0.20, bottomFraction: 0.20, topFraction: 0.20),
        overlay: OverlayConfig(cornerRadius: 8, borderWidth: 3, overlayColor: "blue"),
        behavior: BehaviorConfig(dropZoneHoverDelay: 0.2, dimInactiveWindows: true, dimInactiveOpacity: 0.8, dimAnimationDuration: 1.0, animationDuration: 0.15, dimColor: "black", logPath: ""),
        wallpaper: WallpaperConfig(enabled: false, path: "", scaling: "fill"),
        shortcuts: ShortcutsConfig(tileAll: "cmd+'", tile: "cmd+;", resetLayout: "", refresh: "", flipOrientation: "", focusLeft: "ctrl+opt+left", focusRight: "ctrl+opt+right", focusUp: "ctrl+opt+up", focusDown: "ctrl+opt+down", scroll: "cmd+[", scrollAll: "cmd+]", swapLeft: "ctrl+shift+left", swapRight: "ctrl+shift+right", swapUp: "ctrl+shift+up", swapDown: "ctrl+shift+down", toggleWallpaper: ""),
        commands: [CommandConfig(shortcut: "cmd+enter", run: "open -n -a Alacritty")]
    ))

    /// Full key paths of fields absent from the YAML file.
    var missingKeys: [String] {
        var missing: [String] = []
        let s = config
        func check<T>(_ val: T?, _ path: String) { if val == nil { missing.append(path) } }
        check(s?.layout?.innerGap,              "config.layout.innerGap")
        check(s?.layout?.outerGaps?.left,       "config.layout.outerGaps.left")
        check(s?.layout?.outerGaps?.top,        "config.layout.outerGaps.top")
        check(s?.layout?.outerGaps?.right,      "config.layout.outerGaps.right")
        check(s?.layout?.outerGaps?.bottom,     "config.layout.outerGaps.bottom")
        check(s?.layout?.fallbackWidthFraction,  "config.layout.fallbackWidthFraction")
        check(s?.layout?.maxWidthFraction,       "config.layout.maxWidthFraction")
        check(s?.layout?.maxHeightFraction,      "config.layout.maxHeightFraction")
        check(s?.layout?.scrollCenterDefaultWidthFraction, "config.layout.scrollCenterDefaultWidthFraction")
        check(s?.dropZones?.leftFraction,        "config.dropZones.leftFraction")
        check(s?.dropZones?.rightFraction,       "config.dropZones.rightFraction")
        check(s?.dropZones?.bottomFraction,      "config.dropZones.bottomFraction")
        check(s?.dropZones?.topFraction,         "config.dropZones.topFraction")
        check(s?.overlay?.cornerRadius,          "config.overlay.cornerRadius")
        check(s?.overlay?.borderWidth,           "config.overlay.borderWidth")
        check(s?.overlay?.overlayColor,          "config.overlay.overlayColor")
        check(s?.behavior?.dropZoneHoverDelay,   "config.behavior.dropZoneHoverDelay")
        check(s?.behavior?.dimInactiveWindows,   "config.behavior.dimInactiveWindows")
        check(s?.behavior?.dimInactiveOpacity,      "config.behavior.dimInactiveOpacity")
        check(s?.behavior?.dimAnimationDuration,       "config.behavior.dimAnimationDuration")
        check(s?.behavior?.animationDuration,          "config.behavior.animationDuration")
        check(s?.behavior?.dimColor,                   "config.behavior.dimColor")
        check(s?.behavior?.logPath,                    "config.behavior.logPath")
        check(s?.wallpaper?.enabled,                   "config.wallpaper.enabled")
        check(s?.wallpaper?.path,                      "config.wallpaper.path")
        check(s?.wallpaper?.scaling,                   "config.wallpaper.scaling")
        check(s?.shortcuts?.tileAll,             "config.shortcuts.tileAll")
        check(s?.shortcuts?.tile,               "config.shortcuts.tile")
        check(s?.shortcuts?.resetLayout,        "config.shortcuts.resetLayout")
        check(s?.shortcuts?.refresh,            "config.shortcuts.refresh")
        check(s?.shortcuts?.flipOrientation,    "config.shortcuts.flipOrientation")
        check(s?.shortcuts?.focusLeft,          "config.shortcuts.focusLeft")
        check(s?.shortcuts?.focusRight,         "config.shortcuts.focusRight")
        check(s?.shortcuts?.focusUp,            "config.shortcuts.focusUp")
        check(s?.shortcuts?.focusDown,          "config.shortcuts.focusDown")
        check(s?.shortcuts?.scroll,             "config.shortcuts.scroll")
        check(s?.shortcuts?.scrollAll,          "config.shortcuts.scrollAll")
        check(s?.shortcuts?.swapLeft,           "config.shortcuts.swapLeft")
        check(s?.shortcuts?.swapRight,          "config.shortcuts.swapRight")
        check(s?.shortcuts?.swapUp,             "config.shortcuts.swapUp")
        check(s?.shortcuts?.swapDown,           "config.shortcuts.swapDown")
        check(s?.shortcuts?.toggleWallpaper,    "config.shortcuts.toggleWallpaper")
        return missing
    }

    /// Returns a copy where every nil field is filled from defaults.
    func mergedWithDefaults() -> ConfigData {
        let d = ConfigData.defaults.config!
        let s = config
        return ConfigData(config: ConfigSection(
            layout: LayoutConfig(
                innerGap:               s?.layout?.innerGap               ?? d.layout!.innerGap,
                outerGaps: OuterGapsConfig(
                    left:   s?.layout?.outerGaps?.left   ?? d.layout!.outerGaps!.left,
                    top:    s?.layout?.outerGaps?.top    ?? d.layout!.outerGaps!.top,
                    right:  s?.layout?.outerGaps?.right  ?? d.layout!.outerGaps!.right,
                    bottom: s?.layout?.outerGaps?.bottom ?? d.layout!.outerGaps!.bottom
                ),
                fallbackWidthFraction:  s?.layout?.fallbackWidthFraction  ?? d.layout!.fallbackWidthFraction,
                maxWidthFraction:       s?.layout?.maxWidthFraction       ?? d.layout!.maxWidthFraction,
                maxHeightFraction:      s?.layout?.maxHeightFraction      ?? d.layout!.maxHeightFraction,
                scrollCenterDefaultWidthFraction: s?.layout?.scrollCenterDefaultWidthFraction ?? d.layout!.scrollCenterDefaultWidthFraction
            ),
            dropZones: DropZoneConfig(
                leftFraction:   s?.dropZones?.leftFraction   ?? d.dropZones!.leftFraction,
                rightFraction:  s?.dropZones?.rightFraction  ?? d.dropZones!.rightFraction,
                bottomFraction: s?.dropZones?.bottomFraction ?? d.dropZones!.bottomFraction,
                topFraction:    s?.dropZones?.topFraction    ?? d.dropZones!.topFraction
            ),
            overlay: OverlayConfig(
                cornerRadius: s?.overlay?.cornerRadius ?? d.overlay!.cornerRadius,
                borderWidth:  s?.overlay?.borderWidth  ?? d.overlay!.borderWidth,
                overlayColor: s?.overlay?.overlayColor ?? d.overlay!.overlayColor
            ),
            behavior: BehaviorConfig(
                dropZoneHoverDelay:  s?.behavior?.dropZoneHoverDelay  ?? d.behavior!.dropZoneHoverDelay,
                dimInactiveWindows:  s?.behavior?.dimInactiveWindows  ?? d.behavior!.dimInactiveWindows,
                dimInactiveOpacity:       s?.behavior?.dimInactiveOpacity       ?? d.behavior!.dimInactiveOpacity,
                dimAnimationDuration:     s?.behavior?.dimAnimationDuration     ?? d.behavior!.dimAnimationDuration,
                animationDuration:        s?.behavior?.animationDuration        ?? d.behavior!.animationDuration,
                dimColor:                 s?.behavior?.dimColor                 ?? d.behavior!.dimColor,
                logPath:                  s?.behavior?.logPath                  ?? d.behavior!.logPath
            ),
            wallpaper: WallpaperConfig(
                enabled: s?.wallpaper?.enabled ?? d.wallpaper!.enabled,
                path:    s?.wallpaper?.path    ?? d.wallpaper!.path,
                scaling: s?.wallpaper?.scaling ?? d.wallpaper!.scaling
            ),
            shortcuts: ShortcutsConfig(
                tileAll:         s?.shortcuts?.tileAll         ?? d.shortcuts!.tileAll,
                tile:            s?.shortcuts?.tile            ?? d.shortcuts!.tile,
                resetLayout:     s?.shortcuts?.resetLayout     ?? d.shortcuts!.resetLayout,
                refresh:         s?.shortcuts?.refresh         ?? d.shortcuts!.refresh,
                flipOrientation: s?.shortcuts?.flipOrientation ?? d.shortcuts!.flipOrientation,
                focusLeft:       s?.shortcuts?.focusLeft       ?? d.shortcuts!.focusLeft,
                focusRight:      s?.shortcuts?.focusRight      ?? d.shortcuts!.focusRight,
                focusUp:         s?.shortcuts?.focusUp         ?? d.shortcuts!.focusUp,
                focusDown:       s?.shortcuts?.focusDown       ?? d.shortcuts!.focusDown,
                scroll:          s?.shortcuts?.scroll          ?? d.shortcuts!.scroll,
                scrollAll:       s?.shortcuts?.scrollAll       ?? d.shortcuts!.scrollAll,
                swapLeft:        s?.shortcuts?.swapLeft        ?? d.shortcuts!.swapLeft,
                swapRight:       s?.shortcuts?.swapRight       ?? d.shortcuts!.swapRight,
                swapUp:          s?.shortcuts?.swapUp          ?? d.shortcuts!.swapUp,
                swapDown:        s?.shortcuts?.swapDown        ?? d.shortcuts!.swapDown,
                toggleWallpaper: s?.shortcuts?.toggleWallpaper ?? d.shortcuts!.toggleWallpaper
            ),
            commands: s?.commands ?? d.commands
        ))
    }
}
