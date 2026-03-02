//
//  SnapLayout.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

extension WindowSnapper {

    /// Returns the drop target (key + zone) for the window currently being dragged,
    /// or `nil` if the dragged window is not over any other snapped window.
    static func findDropTarget(for key: SnapKey) -> DropTarget? {
        guard let screen = NSScreen.main else { return nil }

        // Use the live cursor X — identical to AX X (both are left-to-right).
        let cursorX = NSEvent.mouseLocation.x
        let entries = SnapRegistry.shared.allEntries()

        for item in entries where item.key != key {
            guard let range = xRange(for: item.key, entries: entries, screen: screen) else { continue }
            guard range.contains(cursorX) else { continue }

            let windowWidth = range.upperBound - range.lowerBound
            let leftEnd     = range.lowerBound + windowWidth * Config.dropZoneFraction
            let rightStart  = range.lowerBound + windowWidth * (1 - Config.dropZoneFraction)

            let zone: DropZone
            if cursorX < leftEnd {
                zone = .left
            } else if cursorX > rightStart {
                zone = .right
            } else {
                zone = .center
            }

            return DropTarget(key: item.key, zone: zone)
        }
        return nil
    }

    /// Frame of the gap to the left of `targetKey`'s window, in AppKit screen coordinates.
    static func leftGapFrame(for targetKey: SnapKey, screen: NSScreen) -> CGRect? {
        let entries = SnapRegistry.shared.allEntries()
        guard let range = xRange(for: targetKey, entries: entries, screen: screen),
              let entry = entries.first(where: { $0.key == targetKey })?.entry else { return nil }

        let primaryHeight = NSScreen.screens[0].frame.height
        let axY           = primaryHeight - screen.visibleFrame.maxY + Config.gap
        let appKitY       = primaryHeight - axY - entry.height

        return CGRect(
            x:      range.lowerBound - Config.gap,
            y:      appKitY,
            width:  Config.gap,
            height: entry.height
        )
    }

    /// Frame of the gap to the right of `targetKey`'s window, in AppKit screen coordinates.
    static func rightGapFrame(for targetKey: SnapKey, screen: NSScreen) -> CGRect? {
        let entries = SnapRegistry.shared.allEntries()
        guard let range = xRange(for: targetKey, entries: entries, screen: screen),
              let entry = entries.first(where: { $0.key == targetKey })?.entry else { return nil }

        let primaryHeight = NSScreen.screens[0].frame.height
        let axY           = primaryHeight - screen.visibleFrame.maxY + Config.gap
        let appKitY       = primaryHeight - axY - entry.height

        return CGRect(
            x:      range.upperBound,
            y:      appKitY,
            width:  Config.gap,
            height: entry.height
        )
    }

    static func applyPosition(
        to window: AXUIElement,
        key: SnapKey,
        entries: [(key: SnapKey, entry: SnapEntry)]? = nil
    ) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let primaryHeight = NSScreen.screens[0].frame.height

        let allEntries = entries ?? SnapRegistry.shared.allEntries()
        guard let myEntry = allEntries.first(where: { $0.key == key })?.entry else { return }

        // Sum widths of all windows in lower slots to compute this window's X position.
        var xOffset = visible.minX + Config.gap
        for item in allEntries {
            if item.entry.slot == myEntry.slot { break }
            xOffset += item.entry.width + Config.gap
        }

        let axY = primaryHeight - visible.maxY + Config.gap

        var origin = CGPoint(x: xOffset, y: axY)
        var size   = CGSize(width: myEntry.width, height: myEntry.height)

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
        for targetKey: SnapKey,
        entries: [(key: SnapKey, entry: SnapEntry)],
        screen: NSScreen
    ) -> ClosedRange<CGFloat>? {
        guard let myEntry = entries.first(where: { $0.key == targetKey })?.entry else { return nil }
        let visible = screen.visibleFrame

        var xOffset = visible.minX + Config.gap
        for item in entries {
            if item.entry.slot == myEntry.slot { break }
            xOffset += item.entry.width + Config.gap
        }
        return xOffset...(xOffset + myEntry.width)
    }
}
