//
//  ResizeObserver+SwapOverlay.swift
//  UnnamedWindowManager
//

import AppKit

extension ResizeObserver {

    func updateSwapOverlay(dropTarget: DropTarget?, draggedWindow: AXUIElement) {
        guard let drop = dropTarget,
              let targetElement = elements[drop.window],
              let axOrigin = readOrigin(of: targetElement),
              let axSize   = readSize(of: targetElement) else {
            hideSwapOverlay()
            return
        }

        let screenHeight = NSScreen.screens[0].frame.height
        let appKitY = screenHeight - axOrigin.y - axSize.height
        let fullFrame = CGRect(x: axOrigin.x, y: appKitY, width: axSize.width, height: axSize.height)
        let overlayFrame = zoneFrame(for: drop.zone, in: fullFrame)
        let draggedWindowNumber = windowID(of: draggedWindow).map(Int.init)
        showSwapOverlay(frame: overlayFrame, belowWindow: draggedWindowNumber)
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
        }
    }

    func showSwapOverlay(frame: CGRect, belowWindow windowNumber: Int?) {
        if swapOverlay == nil {
            let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            win.isOpaque = false
            win.backgroundColor = .clear
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .transient]

            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = Config.overlayFillColor.cgColor
            view.layer?.borderColor = Config.overlayBorderColor.cgColor
            view.layer?.borderWidth = Config.overlayBorderWidth
            view.layer?.cornerRadius = Config.overlayCornerRadius
            win.contentView = view
            swapOverlay = win
        }
        swapOverlay?.setFrame(frame, display: false)
        if let windowNumber {
            swapOverlay?.order(.below, relativeTo: windowNumber)
        } else {
            swapOverlay?.orderFront(nil)
        }
    }

    func hideSwapOverlay() {
        swapOverlay?.orderOut(nil)
    }
}
