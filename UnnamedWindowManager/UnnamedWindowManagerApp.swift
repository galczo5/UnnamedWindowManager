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
                let entries = SnapRegistry.shared.allEntries()
                var lines: [String] = []
                for item in entries {
                    lines.append(String(format: "slot %d  row %d  pid %-6d  w %6.1f  h %6.1f",
                                        item.entry.slot, item.entry.row,
                                        item.key.pid,
                                        item.entry.width, item.entry.height))
                }
                let alert = NSAlert()
                alert.messageText = "Snapped Windows (\(entries.count))"
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
