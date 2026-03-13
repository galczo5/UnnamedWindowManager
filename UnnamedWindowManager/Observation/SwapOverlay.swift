import AppKit

// Manages the translucent overlay window shown over the drop target during a window drag.
final class SwapOverlay {
    private var window: NSWindow?
    private var currentTarget: DropTarget?

    func update(dropTarget: DropTarget?, draggedWindow: AXUIElement, elements: [WindowSlot: AXUIElement]) {
        guard let drop = dropTarget else {
            hide()
            return
        }

        if let cur = currentTarget, cur.window == drop.window, cur.zone == drop.zone {
            return
        }
        currentTarget = drop

        guard let targetElement = elements[drop.window],
              let axOrigin = readOrigin(of: targetElement),
              let axSize   = readSize(of: targetElement) else {
            hide()
            return
        }

        let screenHeight = NSScreen.screens[0].frame.height
        let appKitY = screenHeight - axOrigin.y - axSize.height
        let fullFrame = CGRect(x: axOrigin.x, y: appKitY, width: axSize.width, height: axSize.height)
        let overlayFrame = zoneFrame(for: drop.zone, in: fullFrame)
        let draggedWindowNumber = windowID(of: draggedWindow).map(Int.init)
        show(frame: overlayFrame, belowWindow: draggedWindowNumber)
    }

    func show(frame: CGRect, belowWindow windowNumber: Int?) {
        if window == nil {
            let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            win.isOpaque = false
            win.backgroundColor = .clear
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .transient]

            let view = NSView()
            view.wantsLayer = true
            win.contentView = view
            window = win
        }
        window?.contentView?.layer?.backgroundColor = Config.overlayFillColor.cgColor
        window?.contentView?.layer?.borderColor = Config.overlayBorderColor.cgColor
        window?.contentView?.layer?.borderWidth = Config.overlayBorderWidth
        window?.contentView?.layer?.cornerRadius = Config.overlayCornerRadius
        window?.setFrame(frame, display: false)
        if let windowNumber {
            window?.order(.below, relativeTo: windowNumber)
        } else {
            window?.orderFront(nil)
        }
    }

    func hide() {
        currentTarget = nil
        window?.orderOut(nil)
    }

    private func zoneFrame(for zone: DropZone, in full: CGRect) -> CGRect {
        switch zone {
        case .left:
            return CGRect(x: full.minX, y: full.minY,
                          width: full.width / 2, height: full.height)
        case .right:
            return CGRect(x: full.minX + full.width / 2, y: full.minY,
                          width: full.width / 2, height: full.height)
        case .top:   // AppKit y↑: top of window = high y values
            return CGRect(x: full.minX, y: full.minY + full.height / 2,
                          width: full.width, height: full.height / 2)
        case .bottom:
            return CGRect(x: full.minX, y: full.minY,
                          width: full.width, height: full.height / 2)
        case .center:
            return full
        }
    }
}
