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
        let key = ResizeObserver.shared.keysByHash[UInt(windowID)]
        let animating = key.map { ResizeObserver.shared.reapplying.contains($0) } ?? false
        if animating || isAtExpectedPosition(axElement: axElement, windowID: windowID) {
            applyFull(axElement: axElement, windowID: windowID)
        } else {
            overlay?.orderOut(nil)
        }
    }

    func hide() {
        activeWindowID = nil
        configuredForID = nil
        overlay?.orderOut(nil)
    }

    func recheckActive() {
        guard let activeID = activeWindowID,
              let key = ResizeObserver.shared.keysByHash[UInt(activeID)],
              let axElement = ResizeObserver.shared.elements[key] else { return }
        updateIfActive(key: key, axElement: axElement)
    }

    func updateIfActive(key: WindowSlot, axElement: AXUIElement) {
        guard let activeID = activeWindowID,
              key.windowHash == UInt(activeID) else { return }
        if ResizeObserver.shared.reapplying.contains(key) {
            // Window is being animated by layout — follow it without a position check.
            moveOverlay(axElement: axElement, windowID: activeID)
            return
        }
        if isAtExpectedPosition(axElement: axElement, windowID: activeID) {
            if overlay?.isVisible == true {
                moveOverlay(axElement: axElement, windowID: activeID)
            } else {
                applyFull(axElement: axElement, windowID: activeID)
            }
        } else {
            overlay?.orderOut(nil)
        }
    }

    // MARK: - Private

    private func isAtExpectedPosition(axElement: AXUIElement, windowID: CGWindowID) -> Bool {
        let hash = UInt(windowID)
        // Use only the service that currently owns this window to avoid stale cache cross-contamination.
        let expected: (pos: CGPoint, size: CGSize)?
        if let key = ResizeObserver.shared.keysByHash[hash], ScrollingRootStore.shared.isTracked(key) {
            expected = ScrollingLayoutService.shared.expectedAXFrame(for: hash)
        } else {
            expected = LayoutService.shared.expectedAXFrame(for: hash)
        }
        guard let expected,
              let actualPos = readOrigin(of: axElement),
              let actualSize = readSize(of: axElement) else {
            return true
        }
        let tolerance: CGFloat = 2
        return abs(actualPos.x - expected.pos.x) <= tolerance
            && abs(actualPos.y - expected.pos.y) <= tolerance
            && abs(actualSize.width - expected.size.width) <= tolerance
            && abs(actualSize.height - expected.size.height) <= tolerance
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
