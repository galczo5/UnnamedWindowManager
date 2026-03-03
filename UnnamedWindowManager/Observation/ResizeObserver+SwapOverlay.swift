//
//  ResizeObserver+SwapOverlay.swift
//  UnnamedWindowManager
//

import AppKit

extension ResizeObserver {

    func updateSwapOverlay(for draggedKey: ManagedWindow, draggedWindow: AXUIElement) {
        guard let screen = NSScreen.main,
              let sourceSlotIndex = ManagedSlotRegistry.shared.slotIndex(for: draggedKey),
              let target = WindowSnapper.findDropTarget(forWindowIn: sourceSlotIndex) else {
            hideSwapOverlay()
            return
        }

        let slots = ManagedSlotRegistry.shared.allSlots()
        let frame: CGRect?
        switch target.zone {
        case .left:
            frame = WindowSnapper.leftGapFrame(forSlot: target.slotIndex, slots: slots, screen: screen)
        case .right:
            frame = WindowSnapper.rightGapFrame(forSlot: target.slotIndex, slots: slots, screen: screen)
        case .bottom:
            frame = WindowSnapper.bottomSplitOverlayFrame(forSlot: target.slotIndex, slots: slots, screen: screen)
        case .center:
            // Overlay over the full target slot: use live AX bounds of the first window.
            let targetSlot = slots[target.slotIndex]
            guard let firstWindow = targetSlot.windows.first,
                  let targetElement = elements[firstWindow],
                  let axOrigin = WindowSnapper.readOrigin(of: targetElement),
                  let axSize   = WindowSnapper.readSize(of: targetElement) else {
                hideSwapOverlay()
                return
            }
            let screenHeight = NSScreen.screens[0].frame.height
            let appKitOrigin = CGPoint(x: axOrigin.x, y: screenHeight - axOrigin.y - axSize.height)
            frame = CGRect(origin: appKitOrigin, size: axSize)
        }

        guard let overlayFrame = frame else { hideSwapOverlay(); return }

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
