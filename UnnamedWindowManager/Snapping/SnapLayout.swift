//
//  SnapLayout.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

extension WindowSnapper {

    /// Returns the key of the snapped window whose horizontal zone contains the mid-X of `window`,
    /// or `nil` if the window was dropped over empty space.
    static func findSwapTarget(for key: SnapKey, window: AXUIElement) -> SnapKey? {
        guard let screen = NSScreen.main,
              let droppedSize = readSize(of: window),
              let droppedOrigin = readOrigin(of: window) else { return nil }

        let droppedMidX = droppedOrigin.x + droppedSize.width / 2
        let entries = SnapRegistry.shared.allEntries()

        return entries.first(where: { item in
            item.key != key &&
            xRange(for: item.key, entries: entries, screen: screen)?.contains(droppedMidX) == true
        })?.key
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
