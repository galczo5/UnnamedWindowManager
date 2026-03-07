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
        Logger.shared.log("Config: reloaded from disk")
    }

    private var s: ConfigData.ConfigSection { data.config! }

    static var gap: CGFloat                   { shared.s.layout!.gap! }
    static var fallbackWidthFraction: CGFloat  { shared.s.layout!.fallbackWidthFraction! }
    static var maxWidthFraction: CGFloat       { shared.s.layout!.maxWidthFraction! }
    static var maxHeightFraction: CGFloat      { shared.s.layout!.maxHeightFraction! }
    static var dropZoneLeftFraction: CGFloat   { shared.s.dropZones!.leftFraction! }
    static var dropZoneRightFraction: CGFloat  { shared.s.dropZones!.rightFraction! }
    static var dropZoneBottomFraction: CGFloat { shared.s.dropZones!.bottomFraction! }
    static var dropZoneTopFraction: CGFloat    { shared.s.dropZones!.topFraction! }
    static var overlayCornerRadius: CGFloat    { shared.s.overlay!.cornerRadius! }
    static var overlayBorderWidth: CGFloat     { shared.s.overlay!.borderWidth! }
    static var autoSnap: Bool                  { shared.s.behavior!.autoSnap! }
    static var autoOrganize: Bool              { shared.s.behavior!.autoOrganize! }
    static var organizeShortcut: String        { shared.s.shortcuts?.organize ?? "cmd+'" }

    static let overlayFillColor: NSColor   = .systemBlue.withAlphaComponent(0.2)
    static let overlayBorderColor: NSColor  = .systemBlue.withAlphaComponent(0.8)
    static let logFilePath: String          = NSHomeDirectory() + "/.unnamed.log"
}
