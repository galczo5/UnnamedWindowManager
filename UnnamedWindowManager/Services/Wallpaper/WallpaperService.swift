import AppKit

// Manages one wallpaper window per connected screen, driven by config.
final class WallpaperService {
    static let shared = WallpaperService()
    private init() {}

    private(set) var isActive: Bool = false
    private var windows: [CGDirectDisplayID: WallpaperWindow] = [:]

    func toggle() {
        if isActive {
            removeAll()
        } else {
            show()
        }
    }

    func apply() {
        if Config.wallpaperEnabled { show() } else { removeAll() }
    }

    private func show() {
        let path = (Config.wallpaperPath as NSString).expandingTildeInPath
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            removeAll()
            return
        }

        let url = URL(fileURLWithPath: path)
        let scaling = Config.wallpaperScaling
        let currentDisplayIDs = Set(NSScreen.screens.compactMap { displayID(for: $0) })

        for screen in NSScreen.screens {
            guard let id = displayID(for: screen) else { continue }

            if let existing = windows[id] {
                existing.setFrame(screen.frame, display: false)
                configureContent(window: existing, url: url, scaling: scaling)
                existing.orderFront(nil)
                continue
            }

            let win = WallpaperWindow(screen: screen)
            configureContent(window: win, url: url, scaling: scaling)
            windows[id] = win
            win.orderFront(nil)
        }

        for id in windows.keys where !currentDisplayIDs.contains(id) {
            windows[id]?.orderOut(nil)
            windows.removeValue(forKey: id)
        }
        isActive = true
    }

    func removeAll() {
        for (_, win) in windows {
            if let gif = win.contentView as? GifImageView { gif.stop() }
            win.orderOut(nil)
        }
        windows.removeAll()
        isActive = false
    }

    func screenChanged() {
        guard isActive else { return }
        show()
    }

    private func configureContent(window: NSWindow, url: URL, scaling: String) {
        let view: GifImageView
        if let existing = window.contentView as? GifImageView {
            view = existing
        } else {
            view = GifImageView(frame: window.frame)
            view.autoresizingMask = [.width, .height]
            window.contentView = view
        }
        view.scaling = scaling
        view.load(url: url)
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
