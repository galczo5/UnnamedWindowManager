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

    func show(windowID: CGWindowID, axElement: AXUIElement) {
        activeWindowID = windowID
        applyFull(axElement: axElement, windowID: windowID)
    }

    func hide() {
        activeWindowID = nil
        configuredForID = nil
        overlay?.orderOut(nil)
    }

    func updateIfActive(key: WindowSlot, axElement: AXUIElement) {
        guard let activeID = activeWindowID,
              key.windowHash == UInt(activeID) else { return }
        moveOverlay(axElement: axElement, windowID: activeID)
    }

    // MARK: - Private

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
        win.order(.above, relativeTo: Int(windowID))
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
