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

    }

    private var s: ConfigData.ConfigSection { data.config! }

    static var innerGap: CGFloat               { shared.s.layout!.innerGap! }
    static var outerGaps: ConfigData.OuterGapsConfig { shared.s.layout!.outerGaps! }
    static let fallbackWidthFraction: CGFloat  = 0.4
    static let maxWidthFraction: CGFloat       = 0.80
    static let maxHeightFraction: CGFloat      = 1.0
    static let scrollCenterDefaultWidthFraction: CGFloat = 0.9
    static let dropZoneLeftFraction: CGFloat   = 0.20
    static let dropZoneRightFraction: CGFloat  = 0.20
    static let dropZoneBottomFraction: CGFloat = 0.20
    static let dropZoneTopFraction: CGFloat    = 0.20
    static let overlayCornerRadius: CGFloat    = 8
    static let overlayBorderWidth: CGFloat     = 3
    static var overlayFillColor: NSColor {
        (SystemColor.resolve(shared.s.overlay!.overlayColor!) ?? .systemBlue).withAlphaComponent(0.2)
    }
    static var overlayBorderColor: NSColor {
        (SystemColor.resolve(shared.s.overlay!.overlayColor!) ?? .systemBlue).withAlphaComponent(0.8)
    }
    static var focusedBorderWidth: CGFloat     { shared.s.focusedBorder!.width! }
    static var focusedBorderColor: NSColor {
        (SystemColor.resolve(shared.s.focusedBorder!.color!) ?? .white).withAlphaComponent(0.8)
    }
    static var dropZoneHoverDelay: CGFloat     { shared.s.behavior!.dropZoneHoverDelay! }
    static var dimInactiveWindows: Bool        { shared.s.behavior!.dimInactiveWindows! }
    static var dimInactiveOpacity: CGFloat     { shared.s.behavior!.dimInactiveOpacity! }
    static var dimAnimationDuration: CGFloat   { shared.s.behavior!.dimAnimationDuration! }
    static var animationDuration: CGFloat     { shared.s.behavior!.animationDuration! }
    static let scrollCenterMinWidthFraction: CGFloat = 0.50
    static let scrollCenterMaxWidthFraction: CGFloat = 0.95
    static let animatedOnceTTL: TimeInterval  = 0.25
    static let borderRestoreDelay: TimeInterval = 0.1
    static let borderFadeInDuration: TimeInterval = 0.15
    static var dimColor: NSColor               { SystemColor.resolve(shared.s.behavior!.dimColor!) ?? .black }
    static var logPath: String?                { let p = shared.s.behavior!.logPath!; return p.isEmpty ? nil : p }
    static var wallpaperEnabled: Bool          { shared.s.wallpaper!.enabled! }
    static var wallpaperPath: String           { shared.s.wallpaper!.path! }
    static var wallpaperScaling: String        { shared.s.wallpaper!.scaling! }
    static var autoModeKeybinding: String      { shared.s.autoMode!.keybinding! }
    static var autoModeEnabledOnStart: Bool    { shared.s.autoMode!.enabledOnStart! }
    static var tileAllShortcut: String          { shared.s.shortcuts!.tileAll! }
    static var tileShortcut: String            { shared.s.shortcuts!.tile! }
    static var resetLayoutShortcut: String     { shared.s.shortcuts!.resetLayout! }
    static var refreshShortcut: String         { shared.s.shortcuts!.refresh! }
    static var flipOrientationShortcut: String { shared.s.shortcuts!.flipOrientation! }
    static var focusLeftShortcut: String       { shared.s.shortcuts!.focusLeft! }
    static var focusRightShortcut: String      { shared.s.shortcuts!.focusRight! }
    static var focusUpShortcut: String         { shared.s.shortcuts!.focusUp! }
    static var focusDownShortcut: String       { shared.s.shortcuts!.focusDown! }
    static var scrollShortcut: String          { shared.s.shortcuts!.scroll! }
    static var scrollAllShortcut: String       { shared.s.shortcuts!.scrollAll! }
    static var swapLeftShortcut: String        { shared.s.shortcuts!.swapLeft! }
    static var swapRightShortcut: String       { shared.s.shortcuts!.swapRight! }
    static var swapUpShortcut: String          { shared.s.shortcuts!.swapUp! }
    static var swapDownShortcut: String        { shared.s.shortcuts!.swapDown! }
    static var toggleWallpaperShortcut: String { shared.s.shortcuts!.toggleWallpaper! }
    static var commands: [ConfigData.CommandConfig] { shared.s.commands ?? [] }

}
