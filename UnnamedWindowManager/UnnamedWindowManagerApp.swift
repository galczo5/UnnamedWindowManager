import SwiftUI
import AppKit
import ApplicationServices

extension Notification.Name {
    static let snapStateChanged = Notification.Name("snapStateChanged")
    static let windowFocusChanged = Notification.Name("windowFocusChanged")
}

@Observable
final class MenuState {
    var parentOrientation: Orientation? = nil
    var isSnapped: Bool = false
    var isFrontmostSnapped: Bool = false

    func refresh() {
        parentOrientation = OrientFlipHandler.parentOrientation()
        isSnapped = SnapService.shared.snapshotVisibleRoot() != nil
        isFrontmostSnapped = {
            guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
            let pid = frontApp.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            var focusedWindow: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else { return false }
            let key = windowSlot(for: focusedWindow as! AXUIElement, pid: pid)
            return SnapService.shared.isTracked(key)
        }()
    }
}

private func menuLabel(_ base: String, _ shortcut: String) -> String {
    let display = KeybindingService.displayString(shortcut)
    return display.isEmpty ? base : "\(base) (\(display))"
}

// App entry point; defines the menu bar extra and coordinates startup initialization.
@main
struct UnnamedWindowManagerApp: App {
    @State private var menuState = MenuState()

    init() {
        Logger.shared.log("=== UnnamedWindowManager started ===")
        NotificationService.shared.requestAuthorization()
        if Config.autoSnap || Config.autoOrganize {
            AutoSnapObserver.shared.start()
        }
        FocusObserver.shared.start()
        ScreenChangeObserver.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            if menuState.isFrontmostSnapped {
                Button(menuLabel("Unsnap", Config.snapShortcut)) { UnsnapHandler.unsnap() }
            } else {
                Button(menuLabel("Snap", Config.snapShortcut)) { SnapHandler.snap() }
            }
            if menuState.isSnapped {
                Button(menuLabel("Unsnap all", Config.snapAllShortcut)) { UnsnapHandler.unsnapAll() }
            } else {
                Button(menuLabel("Snap all",   Config.snapAllShortcut)) { OrganizeHandler.organize() }
            }
            Button(menuLabel("Reset layout",  Config.resetLayoutShortcut))   { UnsnapHandler.unsnapAll(); OrganizeHandler.organize() }
            Button(menuLabel("Refresh",       Config.refreshShortcut))        { ReapplyHandler.reapplyAll() }
            Divider()
            let orientLabel: String = {
                switch menuState.parentOrientation {
                case .horizontal: return "Change to vertical"
                case .vertical:   return "Change to horizontal"
                case nil:         return "Flip Orientation"
                }
            }()
            Button(menuLabel(orientLabel, Config.flipOrientationShortcut)) {
                OrientFlipHandler.flipOrientation()
                menuState.refresh()
            }
            .onAppear { menuState.refresh() }
            Divider()
            Button("Debug")     { WindowLister.logSlotTree() }
            Divider()
            Button("Open config file") {
                NSWorkspace.shared.open(URL(fileURLWithPath: ConfigLoader.filePath))
            }
            Button("Reload config file") {
                Config.shared.reload()
                KeybindingService.shared.restart()
                if !Config.dimInactiveWindows { WindowOpacityService.shared.restoreAll() }
                ReapplyHandler.reapplyAll()
            }
            Button("Reset config file") {
                ConfigLoader.write(ConfigData.defaults)
                Config.shared.reload()
                KeybindingService.shared.restart()
                ReapplyHandler.reapplyAll()
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            HStack(spacing: 4) {
                if menuState.isSnapped {
                    Text("[snapped]")
                } else {
                    Image(systemName: "rectangle.split.3x1.fill")
                }
            }
            .onAppear {
                menuState.refresh()
                KeybindingService.shared.start()
            }
            .onReceive(NotificationCenter.default.publisher(for: .snapStateChanged)) { _ in
                menuState.refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .windowFocusChanged)) { _ in
                menuState.refresh()
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)) { _ in
                menuState.refresh()
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
