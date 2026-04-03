import AppKit

// Draws a border ring using Core Graphics even-odd clipping (JankyBorders technique).
// The centre is fully transparent, allowing the overlay to sit above the target window.
final class BorderDrawingView: NSView {
    var borderColor: NSColor = .white { didSet { needsDisplay = true } }
    var borderWidth: CGFloat = 8      { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 9     { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let frame = bounds

        ctx.saveGState()
        ctx.clear(frame)

        // The window occupies the overlay bounds inset by borderWidth.
        let windowRect = frame.insetBy(dx: borderWidth, dy: borderWidth)

        // Inner clip path matches the window's rounded corners.
        let innerPath = CGPath(roundedRect: windowRect,
                               cornerWidth: cornerRadius,
                               cornerHeight: cornerRadius,
                               transform: nil)

        // Even-odd clip: outer frame rect + inner rounded rect.
        // Drawing is restricted to the ring between them.
        let clipPath = CGMutablePath()
        clipPath.addRect(frame)
        clipPath.addPath(innerPath)
        ctx.addPath(clipPath)
        ctx.clip(using: .evenOdd)

        // Fill the clipped region with a rounded rect whose radius accounts for borderWidth.
        ctx.setFillColor(borderColor.cgColor)
        let outerPath = CGPath(roundedRect: frame,
                               cornerWidth: cornerRadius + borderWidth,
                               cornerHeight: cornerRadius + borderWidth,
                               transform: nil)
        ctx.addPath(outerPath)
        ctx.fillPath()

        ctx.restoreGState()
    }
}
