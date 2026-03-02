//
//  ResizeObserver+SwapOverlay.swift
//  UnnamedWindowManager
//

import AppKit

extension ResizeObserver {

    func updateSwapOverlay(for draggedKey: SnapKey, draggedWindow: AXUIElement) {
        guard let targetKey = WindowSnapper.findSwapTarget(for: draggedKey, window: draggedWindow),
              let targetElement = elements[targetKey],
              let axOrigin = WindowSnapper.readOrigin(of: targetElement),
              let axSize   = WindowSnapper.readSize(of: targetElement) else {
            hideSwapOverlay()
            return
        }

        // AX coordinates use a top-left origin; convert to AppKit's bottom-left origin.
        let screenHeight = NSScreen.screens[0].frame.height
        let appKitOrigin = CGPoint(x: axOrigin.x, y: screenHeight - axOrigin.y - axSize.height)
        let frame = CGRect(origin: appKitOrigin, size: axSize)
        let draggedWindowNumber = WindowSnapper.windowID(of: draggedWindow).map(Int.init)
        showSwapOverlay(frame: frame, belowWindow: draggedWindowNumber)
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
