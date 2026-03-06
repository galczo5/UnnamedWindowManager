//
//  UnnamedWindowManagerApp.swift
//  UnnamedWindowManager
//
//  Created by Kamil on 02/03/2026.
//

import SwiftUI
import AppKit
import ApplicationServices

@Observable
final class MenuState {
    var parentOrientation: Orientation? = nil

    func refresh() {
        parentOrientation = OrientFlipHandler.parentOrientation()
    }
}

@main
struct UnnamedWindowManagerApp: App {
    @State private var menuState = MenuState()

    init() {
        Logger.shared.log("=== UnnamedWindowManager started ===")
        NotificationService.shared.requestAuthorization()
    }

    var body: some Scene {
        MenuBarExtra("Window Manager", systemImage: "rectangle.split.2x1") {
            Button("Snap")      { SnapHandler.snap()        }
            Button("Unsnap")    { UnsnapHandler.unsnap()    }
            Button("Organize")  { OrganizeHandler.organize() }
            Divider()
            let orientLabel: String = {
                switch menuState.parentOrientation {
                case .horizontal: return "Change to vertical"
                case .vertical:   return "Change to horizontal"
                case nil:         return "Flip Orientation"
                }
            }()
            Button(orientLabel) {
                OrientFlipHandler.flipOrientation()
                menuState.refresh()
            }
            .onAppear { menuState.refresh() }
            Divider()
            Button("Debug")     { WindowLister.logSlotTree() }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
