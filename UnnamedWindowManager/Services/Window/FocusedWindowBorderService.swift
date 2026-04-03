import AppKit

// Draws a border ring above the currently focused managed window using
// Core Graphics even-odd clipping (JankyBorders technique).
final class FocusedWindowBorderService {
    static let shared = FocusedWindowBorderService()
    private init() {}

    private var overlay: NSWindow?
    private var drawingView: BorderDrawingView?
    private(set) var activeWindowID: CGWindowID?

    func show(windowID: CGWindowID, axElement: AXUIElement) {
        activeWindowID = windowID
        updateOverlay(axElement: axElement, windowID: windowID)
    }

    func hide() {
        activeWindowID = nil
        overlay?.orderOut(nil)
    }

    func updateIfActive(key: WindowSlot, axElement: AXUIElement) {
        guard let activeID = activeWindowID,
              key.windowHash == UInt(activeID) else { return }
        updateOverlay(axElement: axElement, windowID: activeID)
    }

    // MARK: - Private

    private func updateOverlay(axElement: AXUIElement, windowID: CGWindowID) {
        guard let frame = windowAppKitFrame(of: axElement) else { return }
        let borderWidth = Config.focusedBorderWidth
        let overlayFrame = frame.insetBy(dx: -borderWidth, dy: -borderWidth)
        let radius = windowCornerRadius(for: windowID)

        let win = overlay ?? makeOverlay()
        overlay = win

        let view = drawingView!
        view.borderColor = Config.focusedBorderColor
        view.borderWidth = borderWidth
        view.cornerRadius = radius
        win.setFrame(overlayFrame, display: true)
        win.order(.above, relativeTo: Int(windowID))
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
