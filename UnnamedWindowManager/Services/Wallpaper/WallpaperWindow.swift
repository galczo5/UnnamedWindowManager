import AppKit

// Borderless window pinned just above the desktop level, used as a wallpaper surface.
final class WallpaperWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = true
        backgroundColor = .black
        ignoresMouseEvents = true
        level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary]
    }
}
