import CoreGraphics

// Decoded representation of config.yml. All fields optional to allow partial files.
struct ConfigData: Codable {
    var config: ConfigSection?

    struct ConfigSection: Codable {
        var layout: LayoutConfig?
        var dropZones: DropZoneConfig?
        var overlay: OverlayConfig?
        var behavior: BehaviorConfig?
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
        var autoSnap: Bool?
        var autoOrganize: Bool?
        var dropZoneHoverDelay: CGFloat?
        var dimInactiveWindows: Bool?
        var dimInactiveOpacity: CGFloat?
        var dimAnimationDuration: CGFloat?
        var dimColor: String?
        var logPath: String?
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
    }

    static let defaults = ConfigData(config: ConfigSection(
        layout: LayoutConfig(innerGap: 5, outerGaps: OuterGapsConfig(left: 20, top: 5, right: 20, bottom: 5), fallbackWidthFraction: 0.4, maxWidthFraction: 0.80, maxHeightFraction: 1.0),
        dropZones: DropZoneConfig(leftFraction: 0.20, rightFraction: 0.20, bottomFraction: 0.20, topFraction: 0.20),
        overlay: OverlayConfig(cornerRadius: 8, borderWidth: 3, overlayColor: "blue"),
        behavior: BehaviorConfig(autoSnap: false, autoOrganize: false, dropZoneHoverDelay: 0.2, dimInactiveWindows: true, dimInactiveOpacity: 0.8, dimAnimationDuration: 1.0, dimColor: "black", logPath: ""),
        shortcuts: ShortcutsConfig(tileAll: "cmd+'", tile: "cmd+;", resetLayout: "", refresh: "", flipOrientation: "", focusLeft: "ctrl+opt+left", focusRight: "ctrl+opt+right", focusUp: "ctrl+opt+up", focusDown: "ctrl+opt+down", scroll: "cmd+[", scrollAll: "cmd+]"),
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
        check(s?.dropZones?.leftFraction,        "config.dropZones.leftFraction")
        check(s?.dropZones?.rightFraction,       "config.dropZones.rightFraction")
        check(s?.dropZones?.bottomFraction,      "config.dropZones.bottomFraction")
        check(s?.dropZones?.topFraction,         "config.dropZones.topFraction")
        check(s?.overlay?.cornerRadius,          "config.overlay.cornerRadius")
        check(s?.overlay?.borderWidth,           "config.overlay.borderWidth")
        check(s?.overlay?.overlayColor,          "config.overlay.overlayColor")
        check(s?.behavior?.autoSnap,             "config.behavior.autoSnap")
        check(s?.behavior?.autoOrganize,         "config.behavior.autoOrganize")
        check(s?.behavior?.dropZoneHoverDelay,   "config.behavior.dropZoneHoverDelay")
        check(s?.behavior?.dimInactiveWindows,   "config.behavior.dimInactiveWindows")
        check(s?.behavior?.dimInactiveOpacity,      "config.behavior.dimInactiveOpacity")
        check(s?.behavior?.dimAnimationDuration,       "config.behavior.dimAnimationDuration")
        check(s?.behavior?.dimColor,                   "config.behavior.dimColor")
        check(s?.behavior?.logPath,                    "config.behavior.logPath")
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
                maxHeightFraction:      s?.layout?.maxHeightFraction      ?? d.layout!.maxHeightFraction
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
                autoSnap:            s?.behavior?.autoSnap            ?? d.behavior!.autoSnap,
                autoOrganize:        s?.behavior?.autoOrganize        ?? d.behavior!.autoOrganize,
                dropZoneHoverDelay:  s?.behavior?.dropZoneHoverDelay  ?? d.behavior!.dropZoneHoverDelay,
                dimInactiveWindows:  s?.behavior?.dimInactiveWindows  ?? d.behavior!.dimInactiveWindows,
                dimInactiveOpacity:       s?.behavior?.dimInactiveOpacity       ?? d.behavior!.dimInactiveOpacity,
                dimAnimationDuration:     s?.behavior?.dimAnimationDuration     ?? d.behavior!.dimAnimationDuration,
                dimColor:                 s?.behavior?.dimColor                 ?? d.behavior!.dimColor,
                logPath:                  s?.behavior?.logPath                  ?? d.behavior!.logPath
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
                scrollAll:       s?.shortcuts?.scrollAll       ?? d.shortcuts!.scrollAll
            ),
            commands: s?.commands ?? d.commands
        ))
    }
}
