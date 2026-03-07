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
    }

    struct ShortcutsConfig: Codable {
        var organize: String?
    }

    static let defaults = ConfigData(config: ConfigSection(
        layout: LayoutConfig(gap: 5, fallbackWidthFraction: 0.4, maxWidthFraction: 0.80, maxHeightFraction: 1.0),
        dropZones: DropZoneConfig(leftFraction: 0.20, rightFraction: 0.20, bottomFraction: 0.20, topFraction: 0.20),
        overlay: OverlayConfig(cornerRadius: 8, borderWidth: 3),
        behavior: BehaviorConfig(autoSnap: true, autoOrganize: true),
        shortcuts: ShortcutsConfig(organize: "cmd+'")
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
        check(s?.shortcuts?.organize,            "config.shortcuts.organize")
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
                autoSnap:     s?.behavior?.autoSnap     ?? d.behavior!.autoSnap,
                autoOrganize: s?.behavior?.autoOrganize ?? d.behavior!.autoOrganize
            ),
            shortcuts: ShortcutsConfig(
                organize: s?.shortcuts?.organize ?? d.shortcuts!.organize
            )
        ))
    }
}
