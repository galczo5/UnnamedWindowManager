import AppKit

// Dims non-focused managed windows using per-root full-screen overlays, one per organized layout root.
// Each overlay lives on the space its root belongs to, so switching spaces never causes a fade transition.
final class WindowOpacityService {
    static let shared = WindowOpacityService()
    private init() {}

    private var overlays: [UUID: NSWindow] = [:]
    private var pendingFadeOuts: [UUID: DispatchWorkItem] = [:]
    // Incremented per-root on every dim() call to invalidate stale fadeOut completion handlers.
    private var dimGenerations: [UUID: Int] = [:]
    private var animationDuration: TimeInterval { TimeInterval(Config.dimAnimationDuration) }

    func dim(rootID: UUID, focusedHash: UInt) {
        guard Config.dimInactiveWindows else {
            scheduleFadeOut(rootID: rootID)
            return
        }

        pendingFadeOuts[rootID]?.cancel()
        pendingFadeOuts.removeValue(forKey: rootID)
        dimGenerations[rootID, default: 0] += 1

        let win = overlays[rootID] ?? makeOverlay()
        overlays[rootID] = win

        win.contentView?.layer?.backgroundColor =
            Config.dimColor.withAlphaComponent(1 - Config.dimInactiveOpacity).cgColor

        let screen = NSScreen.screens[0]
        win.setFrame(screen.frame, display: false)

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

    func restore(hash: UInt) {
        restoreAll()
    }

    func restoreAll() {
        for rootID in overlays.keys {
            scheduleFadeOut(rootID: rootID)
        }
    }

    // MARK: - Private

    // Defers the actual fade by one run-loop cycle so a rapid restoreAll()+dim() pair
    // (e.g. from transient AX notifications during a Space switch) cancels before animating.
    private func scheduleFadeOut(rootID: UUID) {
        pendingFadeOuts[rootID]?.cancel()
        guard let win = overlays[rootID], win.isVisible else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingFadeOuts.removeValue(forKey: rootID)
            self?.fadeOut(rootID: rootID)
        }
        pendingFadeOuts[rootID] = work
        DispatchQueue.main.async(execute: work)
    }

    private func fadeOut(rootID: UUID) {
        guard let win = overlays[rootID], win.isVisible else { return }
        dimGenerations[rootID, default: 0] += 1
        let gen = dimGenerations[rootID]!
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animationDuration
            win.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.dimGenerations[rootID] == gen else { return }
            win.orderOut(nil)
        })
    }

    private func makeOverlay() -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.moveToActiveSpace, .transient]

        let view = NSView()
        view.wantsLayer = true
        win.contentView = view
        return win
    }
}
