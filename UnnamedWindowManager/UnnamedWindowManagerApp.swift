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
            SharedRootStore.shared.initialize(screen: screen)
        }

    }

    var body: some Scene {
        MenuBarExtra("Window Manager", systemImage: "rectangle.split.2x1") {
            Button("Snap")      { WindowSnapper.snap()     }
            Button("Unsnap")    { WindowSnapper.unsnap()   }
            Button("Organize")  { WindowSnapper.organize() }
            Divider()
            Button("Debug")     { WindowLister.logAllWindows() }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
