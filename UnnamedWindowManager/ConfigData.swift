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
    }

    struct LayoutConfig: Codable {
        var gap: CGFloat?
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
    }

    struct BehaviorConfig: Codable {
        var autoSnap: Bool?
        var autoOrganize: Bool?
        var dropZoneHoverDelay: CGFloat?
        var dimInactiveWindows: Bool?
        var dimInactiveOpacity: CGFloat?
        var dimAnimationDuration: CGFloat?
    }

    struct ShortcutsConfig: Codable {
        var organize: String?
        var snap: String?
        var unsnap: String?
        var unsnapAll: String?
        var flipOrientation: String?
        var focusLeft: String?
        var focusRight: String?
        var focusUp: String?
        var focusDown: String?
    }

    static let defaults = ConfigData(config: ConfigSection(
        layout: LayoutConfig(gap: 5, fallbackWidthFraction: 0.4, maxWidthFraction: 0.80, maxHeightFraction: 1.0),
        dropZones: DropZoneConfig(leftFraction: 0.20, rightFraction: 0.20, bottomFraction: 0.20, topFraction: 0.20),
        overlay: OverlayConfig(cornerRadius: 8, borderWidth: 3),
        behavior: BehaviorConfig(autoSnap: true, autoOrganize: true, dropZoneHoverDelay: 0.2, dimInactiveWindows: true, dimInactiveOpacity: 0.8, dimAnimationDuration: 0.15),
        shortcuts: ShortcutsConfig(organize: "cmd+'", snap: "", unsnap: "", unsnapAll: "", flipOrientation: "", focusLeft: "ctrl+opt+left", focusRight: "ctrl+opt+right", focusUp: "ctrl+opt+up", focusDown: "ctrl+opt+down")
    ))

    /// Full key paths of fields absent from the YAML file.
    var missingKeys: [String] {
        var missing: [String] = []
        let s = config
        func check<T>(_ val: T?, _ path: String) { if val == nil { missing.append(path) } }
        check(s?.layout?.gap,                   "config.layout.gap")
        check(s?.layout?.fallbackWidthFraction,  "config.layout.fallbackWidthFraction")
        check(s?.layout?.maxWidthFraction,       "config.layout.maxWidthFraction")
        check(s?.layout?.maxHeightFraction,      "config.layout.maxHeightFraction")
        check(s?.dropZones?.leftFraction,        "config.dropZones.leftFraction")
        check(s?.dropZones?.rightFraction,       "config.dropZones.rightFraction")
        check(s?.dropZones?.bottomFraction,      "config.dropZones.bottomFraction")
        check(s?.dropZones?.topFraction,         "config.dropZones.topFraction")
        check(s?.overlay?.cornerRadius,          "config.overlay.cornerRadius")
        check(s?.overlay?.borderWidth,           "config.overlay.borderWidth")
        check(s?.behavior?.autoSnap,             "config.behavior.autoSnap")
        check(s?.behavior?.autoOrganize,         "config.behavior.autoOrganize")
        check(s?.behavior?.dropZoneHoverDelay,   "config.behavior.dropZoneHoverDelay")
        check(s?.behavior?.dimInactiveWindows,   "config.behavior.dimInactiveWindows")
        check(s?.behavior?.dimInactiveOpacity,      "config.behavior.dimInactiveOpacity")
        check(s?.behavior?.dimAnimationDuration,    "config.behavior.dimAnimationDuration")
        check(s?.shortcuts?.organize,            "config.shortcuts.organize")
        check(s?.shortcuts?.snap,               "config.shortcuts.snap")
        check(s?.shortcuts?.unsnap,             "config.shortcuts.unsnap")
        check(s?.shortcuts?.unsnapAll,          "config.shortcuts.unsnapAll")
        check(s?.shortcuts?.flipOrientation,    "config.shortcuts.flipOrientation")
        check(s?.shortcuts?.focusLeft,          "config.shortcuts.focusLeft")
        check(s?.shortcuts?.focusRight,         "config.shortcuts.focusRight")
        check(s?.shortcuts?.focusUp,            "config.shortcuts.focusUp")
        check(s?.shortcuts?.focusDown,          "config.shortcuts.focusDown")
        return missing
    }

    /// Returns a copy where every nil field is filled from defaults.
    func mergedWithDefaults() -> ConfigData {
        let d = ConfigData.defaults.config!
        let s = config
        return ConfigData(config: ConfigSection(
            layout: LayoutConfig(
                gap:                   s?.layout?.gap                   ?? d.layout!.gap,
                fallbackWidthFraction:  s?.layout?.fallbackWidthFraction  ?? d.layout!.fallbackWidthFraction,
                maxWidthFraction:       s?.layout?.maxWidthFraction        ?? d.layout!.maxWidthFraction,
                maxHeightFraction:      s?.layout?.maxHeightFraction       ?? d.layout!.maxHeightFraction
            ),
            dropZones: DropZoneConfig(
                leftFraction:   s?.dropZones?.leftFraction   ?? d.dropZones!.leftFraction,
                rightFraction:  s?.dropZones?.rightFraction  ?? d.dropZones!.rightFraction,
                bottomFraction: s?.dropZones?.bottomFraction ?? d.dropZones!.bottomFraction,
                topFraction:    s?.dropZones?.topFraction    ?? d.dropZones!.topFraction
            ),
            overlay: OverlayConfig(
                cornerRadius: s?.overlay?.cornerRadius ?? d.overlay!.cornerRadius,
                borderWidth:  s?.overlay?.borderWidth  ?? d.overlay!.borderWidth
            ),
            behavior: BehaviorConfig(
                autoSnap:            s?.behavior?.autoSnap            ?? d.behavior!.autoSnap,
                autoOrganize:        s?.behavior?.autoOrganize        ?? d.behavior!.autoOrganize,
                dropZoneHoverDelay:  s?.behavior?.dropZoneHoverDelay  ?? d.behavior!.dropZoneHoverDelay,
                dimInactiveWindows:  s?.behavior?.dimInactiveWindows  ?? d.behavior!.dimInactiveWindows,
                dimInactiveOpacity:    s?.behavior?.dimInactiveOpacity    ?? d.behavior!.dimInactiveOpacity,
                dimAnimationDuration:  s?.behavior?.dimAnimationDuration  ?? d.behavior!.dimAnimationDuration
            ),
            shortcuts: ShortcutsConfig(
                organize:        s?.shortcuts?.organize        ?? d.shortcuts!.organize,
                snap:            s?.shortcuts?.snap            ?? d.shortcuts!.snap,
                unsnap:          s?.shortcuts?.unsnap          ?? d.shortcuts!.unsnap,
                unsnapAll:       s?.shortcuts?.unsnapAll       ?? d.shortcuts!.unsnapAll,
                flipOrientation: s?.shortcuts?.flipOrientation ?? d.shortcuts!.flipOrientation,
                focusLeft:       s?.shortcuts?.focusLeft       ?? d.shortcuts!.focusLeft,
                focusRight:      s?.shortcuts?.focusRight      ?? d.shortcuts!.focusRight,
                focusUp:         s?.shortcuts?.focusUp         ?? d.shortcuts!.focusUp,
                focusDown:       s?.shortcuts?.focusDown       ?? d.shortcuts!.focusDown
            )
        ))
    }
}
