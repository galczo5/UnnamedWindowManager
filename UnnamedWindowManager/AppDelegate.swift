import AppKit

// NSApplicationDelegate that restores all tiled and scrolled windows before the app exits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        UntileHandler.untileAllSpaces()
        UnscrollHandler.unscrollAllSpaces()
    }
}
