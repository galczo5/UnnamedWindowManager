//
//  SnapLayout.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

extension WindowSnapper {

    /// Returns the drop target (slot index + zone) for the window currently being dragged,
    /// or `nil` if the cursor is not over any other slot.
    static func findDropTarget(forWindowIn sourceSlotIndex: Int) -> DropTarget? {
        guard let screen = NSScreen.main else { return nil }

        let cursorX       = NSEvent.mouseLocation.x
        let cursorY       = NSEvent.mouseLocation.y   // AppKit coords (bottom-left origin)
        let primaryHeight = NSScreen.screens[0].frame.height
        let slots         = ManagedSlotRegistry.shared.allSlots()

        for (si, slot) in slots.enumerated() where si != sourceSlotIndex {
            guard let range = xRange(forSlot: si, slots: slots, screen: screen) else { continue }
            guard range.contains(cursorX) else { continue }

            let windowWidth = range.upperBound - range.lowerBound
            let leftEnd     = range.lowerBound + windowWidth * Config.dropZoneFraction
            let rightStart  = range.lowerBound + windowWidth * (1 - Config.dropZoneFraction)

            // Horizontal-only zones — checked first.
            if cursorX < leftEnd  { return DropTarget(slotIndex: si, zone: .left)  }
            if cursorX > rightStart { return DropTarget(slotIndex: si, zone: .right) }

            // Cursor is in the horizontal center — check vertical zone.
            // Only offer .bottom if slot has fewer than 2 windows.
            if slot.windows.count < 2 {
                let totalHeight = slot.windows.reduce(CGFloat(0)) { $0 + $1.height }
                let axY         = primaryHeight - screen.visibleFrame.maxY + Config.gap
                let appKitBottom = primaryHeight - axY - totalHeight
                let bottomZoneTop = appKitBottom + totalHeight * Config.dropZoneBottomFraction

                if cursorY <= bottomZoneTop {
                    return DropTarget(slotIndex: si, zone: .bottom)
                }
            }

            return DropTarget(slotIndex: si, zone: .center)
        }
        return nil
    }

    /// Frame of the gap to the left of `slotIndex`, in AppKit screen coordinates.
    static func leftGapFrame(forSlot slotIndex: Int, slots: [ManagedSlot], screen: NSScreen) -> CGRect? {
        guard let range = xRange(forSlot: slotIndex, slots: slots, screen: screen) else { return nil }
        let slot = slots[slotIndex]
        let totalHeight = slot.windows.reduce(CGFloat(0)) { $0 + $1.height }
            + Config.gap * CGFloat(slot.windows.count - 1)

        let primaryHeight = NSScreen.screens[0].frame.height
        let axY     = primaryHeight - screen.visibleFrame.maxY + Config.gap
        let appKitY = primaryHeight - axY - totalHeight

        return CGRect(
            x:      range.lowerBound - Config.gap,
            y:      appKitY,
            width:  Config.gap,
            height: totalHeight
        )
    }

    /// Frame of the gap to the right of `slotIndex`, in AppKit screen coordinates.
    static func rightGapFrame(forSlot slotIndex: Int, slots: [ManagedSlot], screen: NSScreen) -> CGRect? {
        guard let range = xRange(forSlot: slotIndex, slots: slots, screen: screen) else { return nil }
        let slot = slots[slotIndex]
        let totalHeight = slot.windows.reduce(CGFloat(0)) { $0 + $1.height }
            + Config.gap * CGFloat(slot.windows.count - 1)

        let primaryHeight = NSScreen.screens[0].frame.height
        let axY     = primaryHeight - screen.visibleFrame.maxY + Config.gap
        let appKitY = primaryHeight - axY - totalHeight

        return CGRect(
            x:      range.upperBound,
            y:      appKitY,
            width:  Config.gap,
            height: totalHeight
        )
    }

    /// Frame of the lower-half split rectangle, in AppKit screen coordinates.
    static func bottomSplitOverlayFrame(forSlot slotIndex: Int, slots: [ManagedSlot], screen: NSScreen) -> CGRect? {
        guard let range = xRange(forSlot: slotIndex, slots: slots, screen: screen) else { return nil }
        let slot = slots[slotIndex]
        let visible = screen.visibleFrame
        let windowCount = CGFloat(slot.windows.count + 1)
        let perWindowH  = (visible.height - Config.gap * (windowCount + 1)) / windowCount

        return CGRect(
            x:      range.lowerBound,
            y:      visible.minY + Config.gap,
            width:  slot.width,
            height: perWindowH
        )
    }

    static func applyPosition(
        to window: AXUIElement,
        key: ManagedWindow,
        slots: [ManagedSlot]? = nil
    ) {
        guard let screen = NSScreen.main else { return }
        let visible       = screen.visibleFrame
        let primaryHeight = NSScreen.screens[0].frame.height

        let allSlots = slots ?? ManagedSlotRegistry.shared.allSlots()

        // Find this window's slot and position within it.
        var mySlotIndex: Int?
        var myWindowIndex: Int?
        for (si, slot) in allSlots.enumerated() {
            if let wi = slot.windows.firstIndex(of: key) {
                mySlotIndex = si
                myWindowIndex = wi
                break
            }
        }
        guard let si = mySlotIndex, let wi = myWindowIndex else { return }
        let slot = allSlots[si]
        let myWindow = slot.windows[wi]

        // X: sum widths of all slots before this one.
        var xOffset = visible.minX + Config.gap
        for i in 0..<si {
            xOffset += allSlots[i].width + Config.gap
        }

        // Y: sum heights of all windows before this one in the same slot.
        var axY = primaryHeight - visible.maxY + Config.gap
        for i in 0..<wi {
            axY += slot.windows[i].height + Config.gap
        }

        var origin = CGPoint(x: xOffset, y: axY)
        var size   = CGSize(width: slot.width, height: myWindow.height)

        if let posVal = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        }
    }

    /// Returns `size` with width and height clamped to the per-screen maximums defined in `Config`.
    static func clampSize(_ size: CGSize, screen: NSScreen) -> CGSize {
        let visible = screen.visibleFrame
        let maxW = visible.width  * Config.maxWidthFraction
        let maxH = visible.height * Config.maxHeightFraction - Config.gap * 2
        return CGSize(
            width:  min(size.width,  maxW),
            height: min(size.height, maxH)
        )
    }

    private static func xRange(
        forSlot slotIndex: Int,
        slots: [ManagedSlot],
        screen: NSScreen
    ) -> ClosedRange<CGFloat>? {
        guard slotIndex >= 0, slotIndex < slots.count else { return nil }
        let visible = screen.visibleFrame
        var xOffset = visible.minX + Config.gap
        for i in 0..<slotIndex {
            xOffset += slots[i].width + Config.gap
        }
        return xOffset...(xOffset + slots[slotIndex].width)
    }
}
