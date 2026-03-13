import SwiftUI
import AppKit
import ApplicationServices

extension Notification.Name {
    static let tileStateChanged = Notification.Name("tileStateChanged")
    static let windowFocusChanged = Notification.Name("windowFocusChanged")
}

@Observable
final class MenuState {
    var parentOrientation: Orientation? = nil
    var isTiled: Bool = false
    var isFrontmostTiled: Bool = false
    var isScrolled: Bool = false
    var isFrontmostScrolled: Bool = false

    func refresh() {
        parentOrientation = OrientFlipHandler.parentOrientation()
        isTiled = TileService.shared.snapshotVisibleRoot() != nil
        isScrolled = ScrollingTileService.shared.snapshotVisibleScrollingRoot() != nil
        let frontmostKey: WindowSlot? = {
            guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
            let pid = frontApp.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            var focusedWindow: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else { return nil }
            return windowSlot(for: focusedWindow as! AXUIElement, pid: pid)
        }()
        isFrontmostTiled    = frontmostKey.map { TileService.shared.isTracked($0) } ?? false
        isFrontmostScrolled = frontmostKey.map { ScrollingTileService.shared.isTracked($0) } ?? false
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
        Logger.shared.configure(path: Config.logPath)
        Logger.shared.log("=== UnnamedWindowManager started ===")
        NotificationService.shared.requestAuthorization()
        if Config.autoSnap || Config.autoOrganize {
            AutoTileObserver.shared.start()
        }
        FocusObserver.shared.start()
        ScreenChangeObserver.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            if menuState.isFrontmostTiled {
                Button(menuLabel("Untile", Config.tileShortcut)) { UntileHandler.untile() }
            } else {
                Button(menuLabel("Tile", Config.tileShortcut)) { TileHandler.tile() }
            }
            if menuState.isTiled {
                Button(menuLabel("Untile all", Config.tileAllShortcut)) { UntileHandler.untileAll() }
            } else {
                Button(menuLabel("Tile all",   Config.tileAllShortcut)) { OrganizeHandler.organize() }
            }
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
            if menuState.isFrontmostScrolled {
                Button("Unscroll") { UnscrollHandler.unscroll() }
            } else {
                Button("Scroll") { ScrollingRootHandler.scroll() }
            }
            if menuState.isScrolled {
                Button("Unscroll all") { UnscrollHandler.unscrollAll() }
            } else {
                Button("Scroll all") { ScrollOrganizeHandler.organizeScrolling() }
            }
            Divider()
            Button(menuLabel("Reset layout",  Config.resetLayoutShortcut))   { UntileHandler.untileAll(); OrganizeHandler.organize() }
            Button(menuLabel("Refresh",       Config.refreshShortcut))        { ReapplyHandler.reapplyAll() }
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
            Button("Debug")     { WindowLister.logSlotTree() }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            HStack(spacing: 4) {
                if menuState.isTiled || menuState.isScrolled {
                    if menuState.isTiled    { Text("[tiled]") }
                    if menuState.isScrolled { Text("[scrolled]") }
                } else {
                    Image(systemName: "rectangle.split.3x1.fill")
                }
            }
            .onAppear {
                menuState.refresh()
                KeybindingService.shared.start()
            }
            .onReceive(NotificationCenter.default.publisher(for: .tileStateChanged)) { _ in
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
