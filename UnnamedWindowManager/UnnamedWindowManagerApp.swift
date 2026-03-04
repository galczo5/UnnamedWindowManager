//
//  UnnamedWindowManagerApp.swift
//  UnnamedWindowManager
//
//  Created by Kamil on 02/03/2026.
//

import SwiftUI
import AppKit
import ApplicationServices

@main
struct UnnamedWindowManagerApp: App {
    init() {
        Logger.shared.log("=== UnnamedWindowManager started ===")
        if let screen = NSScreen.main {
            ManagedSlotRegistry.shared.initialize(screen: screen)
        }
        WindowEventMonitor.shared.start()
    }

    var body: some Scene {
        MenuBarExtra("Window Manager", systemImage: "rectangle.split.2x1") {
            Button("Snap")      { WindowSnapper.snap()     }
            Button("Unsnap")    { WindowSnapper.unsnap()   }
            Button("Organize")  { WindowSnapper.organize() }
            Divider()
            Button("Debug") {
                let root   = ManagedSlotRegistry.shared.snapshotRoot()
                let screen = NSScreen.main
                let visible = screen?.visibleFrame
                var lines: [String] = []
                if let v = visible {
                    lines.append(String(format: "Screen visible  x %.1f  y %.1f  w %.1f  h %.1f",
                                        v.minX, v.minY, v.width, v.height))
                    lines.append(String(format: "windowCount %d", ManagedSlotRegistry.shared.windowCount))
                    lines.append("")
                }
                dumpSlot(root, indent: 0, lines: &lines)
                let leafCount = countLeaves(root)
                let alert = NSAlert()
                alert.messageText = "Snapped Windows (\(leafCount) windows)"
                alert.informativeText = lines.isEmpty ? "None" : lines.joined(separator: "\n")
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }

    // MARK: - Debug helpers

    private func dumpSlot(_ slot: ManagedSlot, indent: Int, lines: inout [String]) {
        let pad = String(repeating: "  ", count: indent)
        switch slot.content {
        case .window(let w):
            var title   = "<unknown>"
            var actualW = "-"
            var actualH = "-"
            if let axEl = ResizeObserver.shared.elements[w] {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axEl, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let t = titleRef as? String { title = t }
                if let sz = WindowSnapper.readSize(of: axEl) {
                    actualW = String(format: "%.1f", sz.width)
                    actualH = String(format: "%.1f", sz.height)
                }
            }
            lines.append(String(
                format: "%s[leaf #%d]  \"%@\"",
                pad, slot.order, title
            ))
            lines.append(String(
                format: "%s  stored  w %.1f  h %.1f",
                pad, slot.width, slot.height
            ))
            lines.append(String(
                format: "%s  actual  w %@  h %@",
                pad, actualW, actualH
            ))

        case .slots(let children):
            let orient = slot.orientation == .horizontal ? "horizontal" : "vertical"
            lines.append(String(
                format: "%s[%@ container]  w %.1f  h %.1f  (%d children)",
                pad, orient, slot.width, slot.height, children.count
            ))
            for child in children {
                dumpSlot(child, indent: indent + 1, lines: &lines)
            }
        }
    }

    private func countLeaves(_ slot: ManagedSlot) -> Int {
        switch slot.content {
        case .window:              return 1
        case .slots(let children): return children.reduce(0) { $0 + countLeaves($1) }
        }
    }
}
