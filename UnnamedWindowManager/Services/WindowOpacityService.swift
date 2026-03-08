import AppKit

// Dims non-focused managed windows using a single full-screen overlay ordered below the focused window.
final class WindowOpacityService {
    static let shared = WindowOpacityService()
    private init() {}

    private var overlay: NSWindow?

    /// Shows the full-screen dim overlay just below `focusedHash`.
    /// No-op if `dimInactiveWindows` is false or no visible layout root exists.
    func dim(focusedHash: UInt) {
        guard Config.dimInactiveWindows else {
            hideOverlay()
            return
        }
        guard SnapService.shared.snapshotVisibleRoot() != nil else { return }

        let win = overlay ?? makeOverlay()
        overlay = win

        win.contentView?.layer?.backgroundColor =
            NSColor.black.withAlphaComponent(1 - Config.dimInactiveOpacity).cgColor

        let screen = NSScreen.screens[0]
        win.setFrame(screen.frame, display: false)
        win.order(.below, relativeTo: Int(focusedHash))
    }

    /// Hides the dim overlay.
    func restore(hash: UInt) {
        hideOverlay()
    }

    /// Hides the dim overlay.
    func restoreAll() {
        hideOverlay()
    }

    // MARK: - Private

    private func hideOverlay() {
        overlay?.orderOut(nil)
    }

    private func makeOverlay() -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .transient]

        let view = NSView()
        view.wantsLayer = true
        win.contentView = view
        return win
    }
}
