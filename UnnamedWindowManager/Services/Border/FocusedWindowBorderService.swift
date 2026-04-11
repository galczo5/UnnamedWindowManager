import AppKit

// Draws a border ring above the currently focused managed window using
// Core Graphics even-odd clipping (JankyBorders technique).
final class FocusedWindowBorderService {
    static let shared = FocusedWindowBorderService()
    private init() {}

    private var overlay: NSWindow?
    private var drawingView: BorderDrawingView?
    private(set) var activeWindowID: CGWindowID?
    private var configuredForID: CGWindowID?
    private var suppressedForAnimation = false

    func show(windowID: CGWindowID, axElement: AXUIElement) {
        activeWindowID = windowID
        guard !suppressedForAnimation else { return }
        applyFull(axElement: axElement, windowID: windowID)
    }

    /// Hides the border only if the given key is the currently active window.
    func hideIfActive(key: WindowSlot) {
        guard let activeID = activeWindowID, UInt(activeID) == key.windowHash else { return }
        hide()
    }

    /// Fully hides the border and clears the tracked window. Use when the window leaves the layout.
    func hide() {
        suppressedForAnimation = false
        activeWindowID = nil
        configuredForID = nil
        overlay?.orderOut(nil)
    }

    /// Hides the overlay visually but keeps activeWindowID so recheckActive can restore it after animation.
    func hideForAnimation() {
        suppressedForAnimation = true
        configuredForID = nil
        overlay?.orderOut(nil)
    }

    func recheckActive() {
        suppressedForAnimation = false
        guard let activeID = activeWindowID,
              let key = WindowTracker.shared.keysByHash[UInt(activeID)],
              let axElement = WindowTracker.shared.elements[key] else { return }
        updateIfActive(key: key, axElement: axElement)
    }

    func updateIfActive(key: WindowSlot, axElement: AXUIElement) {
        guard !suppressedForAnimation,
              let activeID = activeWindowID,
              key.windowHash == UInt(activeID) else { return }
        if overlay?.isVisible == true {
            moveOverlay(axElement: axElement, windowID: activeID)
        } else {
            applyFull(axElement: axElement, windowID: activeID)
        }
    }

    // Full setup: drawing properties, corner radius, z-order. Called on focus change.
    private func applyFull(axElement: AXUIElement, windowID: CGWindowID) {
        guard let frame = windowAppKitFrame(of: axElement) else { return }
        let borderWidth = Config.focusedBorderWidth
        let overlayFrame = frame.insetBy(dx: -borderWidth, dy: -borderWidth)

        let win = overlay ?? makeOverlay()
        overlay = win
        configuredForID = windowID

        let view = drawingView!
        view.borderColor = Config.focusedBorderColor
        view.borderWidth = borderWidth
        view.cornerRadius = windowCornerRadius(for: windowID)
        win.setFrame(overlayFrame, display: true)
        win.alphaValue = 0
        win.order(.above, relativeTo: Int(windowID))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Config.borderFadeInDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 1
        }
    }

    // Lightweight reposition: only moves the overlay origin. Called on move/resize notifications.
    private func moveOverlay(axElement: AXUIElement, windowID: CGWindowID) {
        guard let win = overlay,
              let frame = windowAppKitFrame(of: axElement) else { return }
        let borderWidth = Config.focusedBorderWidth
        let overlayFrame = frame.insetBy(dx: -borderWidth, dy: -borderWidth)

        if overlayFrame.size != win.frame.size {
            win.setFrame(overlayFrame, display: true)
        } else {
            win.setFrameOrigin(overlayFrame.origin)
        }
    }

    private func makeOverlay() -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.moveToActiveSpace, .transient]
        let view = BorderDrawingView()
        win.contentView = view
        drawingView = view
        return win
    }

}
