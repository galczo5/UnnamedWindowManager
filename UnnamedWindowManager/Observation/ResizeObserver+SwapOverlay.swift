//
//  ResizeObserver+SwapOverlay.swift
//  UnnamedWindowManager
//

import AppKit

extension ResizeObserver {

    func updateSwapOverlay(for draggedKey: WindowSlot, draggedWindow: AXUIElement) {
        guard let targetWindow = WindowSnapper.findSwapTarget(forKey: draggedKey),
              let targetElement = elements[targetWindow],
              let axOrigin = WindowSnapper.readOrigin(of: targetElement),
              let axSize   = WindowSnapper.readSize(of: targetElement) else {
            hideSwapOverlay()
            return
        }

        let screenHeight = NSScreen.screens[0].frame.height
        let appKitY = screenHeight - axOrigin.y - axSize.height
        let overlayFrame = CGRect(x: axOrigin.x, y: appKitY, width: axSize.width, height: axSize.height)
        let draggedWindowNumber = WindowSnapper.windowID(of: draggedWindow).map(Int.init)
        showSwapOverlay(frame: overlayFrame, belowWindow: draggedWindowNumber)
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
