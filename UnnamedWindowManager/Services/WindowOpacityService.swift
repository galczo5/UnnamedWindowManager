import AppKit

// Dims non-focused managed windows using a single full-screen overlay ordered below the focused window.
final class WindowOpacityService {
    static let shared = WindowOpacityService()
    private init() {}

    private var overlay: NSWindow?
    private var animationDuration: TimeInterval { TimeInterval(Config.dimAnimationDuration) }

    /// Shows the full-screen dim overlay just below `focusedHash`.
    /// No-op if `dimInactiveWindows` is false or no visible layout root exists.
    func dim(focusedHash: UInt) {
        guard Config.dimInactiveWindows else {
            fadeOut()
            return
        }
        guard SnapService.shared.snapshotVisibleRoot() != nil else { return }

        let win = overlay ?? makeOverlay()
        overlay = win

        win.contentView?.layer?.backgroundColor =
            NSColor.black.withAlphaComponent(1 - Config.dimInactiveOpacity).cgColor

        let screen = NSScreen.screens[0]
        win.setFrame(screen.frame, display: false)

        // If the window isn't visible yet, start from zero so the fade-in is smooth.
        if !win.isVisible {
            win.alphaValue = 0
            win.order(.below, relativeTo: Int(focusedHash))
        } else {
            win.order(.below, relativeTo: Int(focusedHash))
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animationDuration
            win.animator().alphaValue = 1
        }
    }

    /// Fades out and hides the dim overlay.
    func restore(hash: UInt) {
        fadeOut()
    }

    /// Fades out and hides the dim overlay.
    func restoreAll() {
        fadeOut()
    }

    // MARK: - Private

    private func fadeOut() {
        guard let win = overlay, win.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animationDuration
            win.animator().alphaValue = 0
        }, completionHandler: {
            win.orderOut(nil)
        })
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
