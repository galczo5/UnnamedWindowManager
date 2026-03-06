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
        NotificationService.shared.requestAuthorization()

    }

    var body: some Scene {
        MenuBarExtra("Window Manager", systemImage: "rectangle.split.2x1") {
            Button("Snap")      { SnapHandler.snap()       }
            Button("Unsnap")    { UnsnapHandler.unsnap()   }
            Button("Organize")  { OrganizeHandler.organize() }
            Divider()
            Button("Debug")     { WindowLister.logAllWindows() }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
