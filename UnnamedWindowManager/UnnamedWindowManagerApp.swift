//
//  UnnamedWindowManagerApp.swift
//  UnnamedWindowManager
//
//  Created by Kamil on 02/03/2026.
//

import SwiftUI
import AppKit
import ApplicationServices

extension Notification.Name {
    static let snapStateChanged = Notification.Name("snapStateChanged")
}

@Observable
final class MenuState {
    var parentOrientation: Orientation? = nil
    var isOrganized: Bool = false

    func refresh() {
        parentOrientation = OrientFlipHandler.parentOrientation()
        isOrganized = SnapService.shared.snapshotVisibleRoot() != nil
    }
}

@main
struct UnnamedWindowManagerApp: App {
    @State private var menuState = MenuState()

    init() {
        Logger.shared.log("=== UnnamedWindowManager started ===")
        NotificationService.shared.requestAuthorization()
        if Config.autoSnap || Config.autoOrganize {
            AutoSnapObserver.shared.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Button("Snap")      { SnapHandler.snap()        }
            Button("Unsnap")     { UnsnapHandler.unsnap()    }
            Button("Unsnap all") { UnsnapHandler.unsnapAll() }
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
        } label: {
            HStack(spacing: 4) {
                if menuState.isOrganized {
                    Text("[organized]")
                } else {
                    Image(systemName: "rectangle.split.3x1.fill")
                }
            }
            .onAppear { menuState.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .snapStateChanged)) { _ in
                menuState.refresh()
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)) { _ in
                menuState.refresh()
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
