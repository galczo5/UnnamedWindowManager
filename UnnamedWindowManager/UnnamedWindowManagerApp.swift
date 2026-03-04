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
        WindowEventMonitor.shared.start()
    }

    var body: some Scene {
        MenuBarExtra("Window Manager", systemImage: "rectangle.split.2x1") {
            Button("Snap")      { WindowSnapper.snap()     }
            Button("Unsnap")    { WindowSnapper.unsnap()   }
            Button("Organize")  { WindowSnapper.organize() }
            Divider()
            Button("Debug") {
                let slots = ManagedSlotRegistry.shared.allSlots()
                var lines: [String] = []
                for (si, slot) in slots.enumerated() {
                    lines.append(String(format: "── Slot %d  slot width %.1f ──", si, slot.width))
                    for (wi, window) in slot.windows.enumerated() {
                        var title = "<unknown>"
                        var actualW = "-"
                        var actualH = "-"
                        if let axEl = ResizeObserver.shared.elements[window] {
                            var titleRef: CFTypeRef?
                            if AXUIElementCopyAttributeValue(axEl, kAXTitleAttribute as CFString, &titleRef) == .success,
                               let t = titleRef as? String { title = t }
                            if let sz = WindowSnapper.readSize(of: axEl) {
                                actualW = String(format: "%.1f", sz.width)
                                actualH = String(format: "%.1f", sz.height)
                            }
                        }
                        lines.append(String(
                            format: "  win %d  \"%@\"\n         stored  w %.1f  h %.1f\n         actual  w %@  h %@",
                            wi, title,
                            slot.width, window.height,
                            actualW, actualH
                        ))
                    }
                }
                let alert = NSAlert()
                alert.messageText = "Snapped Windows (\(slots.count) slots)"
                alert.informativeText = lines.isEmpty ? "None" : lines.joined(separator: "\n\n")
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
