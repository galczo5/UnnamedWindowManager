//
//  SnapLayout.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

extension WindowSnapper {

    // MARK: - Tree layout

    /// Positions all snapped windows by walking the slot tree from the root.
    static func applyLayout(screen: NSScreen) {
        let visible       = screen.visibleFrame
        let primaryHeight = NSScreen.screens[0].frame.height
        // Subtract Config.gap so the first container level adds it back, giving the
        // correct (visible.minX + gap, axTop + gap) position for the first leaf.
        let origin = CGPoint(x: visible.minX, y: primaryHeight - visible.maxY)
        let elements = ResizeObserver.shared.elements
        let root = ManagedSlotRegistry.shared.snapshotRoot()
        applyLayout(root, origin: origin, elements: elements)
    }

    private static func applyLayout(
        _ slot: ManagedSlot,
        origin: CGPoint,
        elements: [ManagedWindow: AXUIElement]
    ) {
        switch slot.content {
        case .window(let w):
            guard let ax = elements[w] else { return }
            var pos  = origin
            var size = CGSize(width: slot.width, height: slot.height)
            Logger.shared.log("key=\(w.windowHash) origin=(\(Int(origin.x)),\(Int(origin.y))) size=(\(Int(size.width))×\(Int(size.height)))")
            if let posVal = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, posVal)
            }
            if let sizeVal = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, sizeVal)
            }

        case .slots(let children):
            // Each container level adds the initial gap before placing its first child.
            var cursor = CGPoint(x: origin.x + Config.gap, y: origin.y + Config.gap)
            for child in children {
                applyLayout(child, origin: cursor, elements: elements)
                if slot.orientation == .horizontal {
                    cursor.x += child.width + Config.gap
                } else {
                    cursor.y += child.height + Config.gap
                }
            }
        }
    }

    // MARK: - Drop zones (disabled — TODO: redesign for tree model)

    /// Returns the drop target for the window currently being dragged.
    /// Disabled until drop zones are redesigned for the tree model.
    static func findDropTarget(forWindowIn sourceSlotIndex: Int) -> DropTarget? {
        return nil  // TODO: redesign for tree model

        // ---- original flat-array code preserved below ----
        guard let screen = NSScreen.main else { return nil }

        let cursorX       = NSEvent.mouseLocation.x
        let cursorY       = NSEvent.mouseLocation.y
        let primaryHeight = NSScreen.screens[0].frame.height
        let slots         = ManagedSlotRegistry.shared.allLeaves()

        for (si, slot) in slots.enumerated() {
            guard let range = xRange(forSlot: si, slots: slots, screen: screen) else { continue }
            guard range.contains(cursorX) else { continue }

            let axY          = primaryHeight - screen.visibleFrame.maxY + Config.gap
            let appKitTop    = primaryHeight - axY
            let appKitBottom = appKitTop - slot.height

            let slotWidth  = range.upperBound - range.lowerBound
            let leftEnd    = range.lowerBound + slotWidth * Config.dropZoneFraction
            let rightStart = range.lowerBound + slotWidth * (1 - Config.dropZoneFraction)

            if cursorX < leftEnd    { return DropTarget(slotIndex: si, windowIndex: 0, zone: .left)  }
            if cursorX > rightStart { return DropTarget(slotIndex: si, windowIndex: 0, zone: .right) }

            guard cursorY <= appKitTop && cursorY >= appKitBottom else { continue }

            if si != sourceSlotIndex {
                let topZoneBound    = appKitTop    - slot.height * Config.dropZoneTopFraction
                let bottomZoneBound = appKitBottom + slot.height * Config.dropZoneBottomFraction
                if cursorY >= topZoneBound    { return DropTarget(slotIndex: si, windowIndex: 0, zone: .top) }
                if cursorY <= bottomZoneBound { return DropTarget(slotIndex: si, windowIndex: 0, zone: .bottom) }
            }
            return DropTarget(slotIndex: si, windowIndex: 0, zone: .center)
        }
        return nil
    }

    // MARK: - Overlay frame helpers (disabled — TODO: redesign for tree model)

    static func leftGapFrame(forSlot slotIndex: Int, slots: [ManagedSlot], screen: NSScreen) -> CGRect? {
        return nil  // TODO: redesign for tree model
    }

    static func rightGapFrame(forSlot slotIndex: Int, slots: [ManagedSlot], screen: NSScreen) -> CGRect? {
        return nil  // TODO: redesign for tree model
    }

    static func bottomSplitOverlayFrame(forSlot slotIndex: Int, slots: [ManagedSlot], screen: NSScreen) -> CGRect? {
        return nil  // TODO: redesign for tree model
    }

    static func topSplitOverlayFrame(forSlot slotIndex: Int, slots: [ManagedSlot], screen: NSScreen) -> CGRect? {
        return nil  // TODO: redesign for tree model
    }

    // MARK: - Size helpers

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
