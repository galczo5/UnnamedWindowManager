//
//  UnnamedWindowManagerApp.swift
//  UnnamedWindowManager
//
//  Created by Kamil on 02/03/2026.
//

import SwiftUI

@main
struct UnnamedWindowManagerApp: App {
    var body: some Scene {
        MenuBarExtra("Window Manager", systemImage: "rectangle.split.2x1") {
            Button("Snap")      { WindowSnapper.snap()     }
            Button("Unsnap")    { WindowSnapper.unsnap()   }
            Button("Organize")  { WindowSnapper.organize() }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
