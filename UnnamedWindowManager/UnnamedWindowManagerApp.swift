//
//  UnnamedWindowManagerApp.swift
//  UnnamedWindowManager
//
//  Created by Kamil on 02/03/2026.
//

import SwiftUI
import AppKit

@main
struct UnnamedWindowManagerApp: App {
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
                    for (wi, window) in slot.windows.enumerated() {
                        lines.append(String(format: "slot %d  win %d  pid %-6d  w %6.1f  h %6.1f",
                                            si, wi,
                                            window.pid,
                                            slot.width, window.height))
                    }
                }
                let alert = NSAlert()
                alert.messageText = "Snapped Windows (\(slots.count) slots)"
                alert.informativeText = lines.isEmpty ? "None" : lines.joined(separator: "\n")
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
