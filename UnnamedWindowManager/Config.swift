import CoreGraphics
import AppKit

// Runtime configuration, loaded from ~/.config/unnamed/config.yml at startup.
final class Config {
    static let shared = Config()
    private var data: ConfigData

    private init() {
        data = ConfigLoader.load()
    }

    func reload() {
        data = ConfigLoader.load()
        Logger.shared.configure(path: Config.logPath)
        Logger.shared.log("Config: reloaded from disk")
        LayoutService.shared.clearCache()
        ScrollingLayoutService.shared.clearCache()
    }

    private var s: ConfigData.ConfigSection { data.config! }

    static var innerGap: CGFloat               { shared.s.layout!.innerGap! }
    static var outerGaps: ConfigData.OuterGapsConfig { shared.s.layout!.outerGaps! }
    static var fallbackWidthFraction: CGFloat  { shared.s.layout!.fallbackWidthFraction! }
    static var maxWidthFraction: CGFloat       { shared.s.layout!.maxWidthFraction! }
    static var maxHeightFraction: CGFloat      { shared.s.layout!.maxHeightFraction! }
    static var dropZoneLeftFraction: CGFloat   { shared.s.dropZones!.leftFraction! }
    static var dropZoneRightFraction: CGFloat  { shared.s.dropZones!.rightFraction! }
    static var dropZoneBottomFraction: CGFloat { shared.s.dropZones!.bottomFraction! }
    static var dropZoneTopFraction: CGFloat    { shared.s.dropZones!.topFraction! }
    static var overlayCornerRadius: CGFloat    { shared.s.overlay!.cornerRadius! }
    static var overlayBorderWidth: CGFloat     { shared.s.overlay!.borderWidth! }
    static var overlayFillColor: NSColor {
        (SystemColor.resolve(shared.s.overlay!.overlayColor!) ?? .systemBlue).withAlphaComponent(0.2)
    }
    static var overlayBorderColor: NSColor {
        (SystemColor.resolve(shared.s.overlay!.overlayColor!) ?? .systemBlue).withAlphaComponent(0.8)
    }
    static var autoSnap: Bool                  { shared.s.behavior!.autoSnap! }
    static var autoOrganize: Bool              { shared.s.behavior!.autoOrganize! }
    static var dropZoneHoverDelay: CGFloat     { shared.s.behavior!.dropZoneHoverDelay! }
    static var dimInactiveWindows: Bool        { shared.s.behavior!.dimInactiveWindows! }
    static var dimInactiveOpacity: CGFloat     { shared.s.behavior!.dimInactiveOpacity! }
    static var dimAnimationDuration: CGFloat   { shared.s.behavior!.dimAnimationDuration! }
    static var dimColor: NSColor               { SystemColor.resolve(shared.s.behavior!.dimColor!) ?? .black }
    static var logPath: String?                { let p = shared.s.behavior!.logPath!; return p.isEmpty ? nil : p }
    static var tileAllShortcut: String          { shared.s.shortcuts!.tileAll! }
    static var tileShortcut: String            { shared.s.shortcuts!.tile! }
    static var resetLayoutShortcut: String     { shared.s.shortcuts!.resetLayout! }
    static var refreshShortcut: String         { shared.s.shortcuts!.refresh! }
    static var flipOrientationShortcut: String { shared.s.shortcuts!.flipOrientation! }
    static var focusLeftShortcut: String       { shared.s.shortcuts!.focusLeft! }
    static var focusRightShortcut: String      { shared.s.shortcuts!.focusRight! }
    static var focusUpShortcut: String         { shared.s.shortcuts!.focusUp! }
    static var focusDownShortcut: String       { shared.s.shortcuts!.focusDown! }
    static var commands: [ConfigData.CommandConfig] { shared.s.commands ?? [] }

}
