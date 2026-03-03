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

        for (si, slot) in slots.enumerated() {
            guard let range = xRange(forSlot: si, slots: slots, screen: screen) else { continue }
            guard range.contains(cursorX) else { continue }

            let axY          = primaryHeight - screen.visibleFrame.maxY + Config.gap
            let totalHeight  = slot.windows.reduce(CGFloat(0)) { $0 + $1.height }
                + Config.gap * CGFloat(slot.windows.count - 1)
            let appKitTop    = primaryHeight - axY
            let appKitBottom = appKitTop - totalHeight

            let slotWidth  = range.upperBound - range.lowerBound
            let leftEnd    = range.lowerBound + slotWidth * Config.dropZoneFraction
            let rightStart = range.lowerBound + slotWidth * (1 - Config.dropZoneFraction)

            // Left / right always valid — even for the source slot (extracts window into new slot).
            if cursorX < leftEnd    { return DropTarget(slotIndex: si, windowIndex: 0, zone: .left)  }
            if cursorX > rightStart { return DropTarget(slotIndex: si, windowIndex: 0, zone: .right) }

            // Cursor is in horizontal center — only proceed if within the slot's Y bounds.
            guard cursorY <= appKitTop && cursorY >= appKitBottom else { continue }

            // Top / bottom only valid for other slots (adding a window to its own slot is a no-op).
            if si != sourceSlotIndex {
                let topZoneBound    = appKitTop    - totalHeight * Config.dropZoneTopFraction
                let bottomZoneBound = appKitBottom + totalHeight * Config.dropZoneBottomFraction

                if cursorY >= topZoneBound    { return DropTarget(slotIndex: si, windowIndex: 0, zone: .top) }
                if cursorY <= bottomZoneBound { return DropTarget(slotIndex: si, windowIndex: 0, zone: .bottom) }
            }

            // Center zone — identify the specific window under the cursor.
            let wi = windowIndexAtCursor(cursorY: cursorY, slot: slot, slotTopAX: axY, primaryHeight: primaryHeight)
            return DropTarget(slotIndex: si, windowIndex: wi, zone: .center)
        }
        return nil
    }

    /// Returns the index of the window under `cursorY` (AppKit coords) within the slot.
    /// Falls back to the last window if the cursor is below all windows.
    private static func windowIndexAtCursor(
        cursorY: CGFloat,
        slot: ManagedSlot,
        slotTopAX: CGFloat,
        primaryHeight: CGFloat
    ) -> Int {
        var axY = slotTopAX
        for (wi, window) in slot.windows.enumerated() {
            let appKitTop    = primaryHeight - axY
            let appKitBottom = appKitTop - window.height
            if cursorY <= appKitTop && cursorY >= appKitBottom { return wi }
            axY += window.height + Config.gap
        }
        return max(slot.windows.count - 1, 0)
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

    /// Frame of the lower split rectangle (where the new bottom window will land), in AppKit screen coordinates.
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

    /// Frame of the upper split rectangle (where the new top window will land), in AppKit screen coordinates.
    static func topSplitOverlayFrame(forSlot slotIndex: Int, slots: [ManagedSlot], screen: NSScreen) -> CGRect? {
        guard let range = xRange(forSlot: slotIndex, slots: slots, screen: screen) else { return nil }
        let slot = slots[slotIndex]
        let visible = screen.visibleFrame
        let windowCount = CGFloat(slot.windows.count + 1)
        let perWindowH  = (visible.height - Config.gap * (windowCount + 1)) / windowCount

        let primaryHeight = NSScreen.screens[0].frame.height
        let axY       = primaryHeight - visible.maxY + Config.gap
        let appKitTop = primaryHeight - axY

        return CGRect(
            x:      range.lowerBound,
            y:      appKitTop - perWindowH,
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
