import SwiftUI
import AppKit
import ApplicationServices
import CoreServices

@Observable
final class MenuState {
    var parentOrientation: Orientation? = nil
    var isTiled: Bool = false
    var isFrontmostTiled: Bool = false
    var isScrolled: Bool = false
    var isFrontmostScrolled: Bool = false
    func refresh() {
        parentOrientation = OrientFlipHandler.parentOrientation()
        isTiled = TilingRootStore.shared.snapshotVisibleRoot() != nil
        isScrolled = ScrollingRootStore.shared.snapshotVisibleScrollingRoot() != nil
        let frontmostKey: WindowSlot? = {
            guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
            let pid = frontApp.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            var focusedWindow: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else { return nil }
            return windowSlot(for: focusedWindow as! AXUIElement, pid: pid)
        }()
        isFrontmostTiled    = frontmostKey.map { TilingRootStore.shared.isTracked($0) } ?? false
        isFrontmostScrolled = frontmostKey.map { ScrollingRootStore.shared.isTracked($0) } ?? false
    }
}

private func menuLabel(_ base: String, _ shortcut: String) -> String {
    let display = KeybindingService.displayString(shortcut)
    return display.isEmpty ? base : "\(base) (\(display))"
}

// App entry point; defines the menu bar extra and coordinates startup initialization.
@main
struct UnnamedWindowManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var menuState = MenuState()

    init() {
        Logger.shared.configure(path: Config.logPath)
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        NotificationService.shared.requestAuthorization()
        FocusObserver.shared.start()
        ScreenParametersChangedObserver.shared.start()
        SpaceChangedObserver.shared.start()
        WindowCreationObserver.shared.start()
        WallpaperService.shared.apply()

        ScreenParametersChangedObserver.shared.subscribe { _ in
            guard let screen = NSScreen.main else { return }
            LayoutService.shared.clearCache()
            ScrollingLayoutService.shared.clearCache()
            TilingEditService.shared.recomputeVisibleRootSizes(screen: screen)
            WallpaperService.shared.screenChanged()
            ReapplyHandler.reapplyAll()
        }

        let state = menuState
        TileStateChangedObserver.shared.subscribe { _ in
            state.refresh()
        }
        WindowFocusChangedObserver.shared.subscribe { _ in
            state.refresh()
        }
        SpaceChangedObserver.shared.subscribe { _ in
            state.refresh()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            if menuState.isFrontmostTiled {
                Button(menuLabel("Untile", Config.tileShortcut)) { UntileHandler.untile() }
            } else {
                Button(menuLabel("Tile", Config.tileShortcut)) { TileHandler.tile() }
                    .disabled(menuState.isScrolled)
            }
            if menuState.isTiled {
                Button(menuLabel("Untile all", Config.tileAllShortcut)) { UntileHandler.untileAll() }
            } else {
                Button(menuLabel("Tile all",   Config.tileAllShortcut)) { TileAllHandler.tileAll() }
                    .disabled(menuState.isScrolled)
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
                Button(menuLabel("Unscroll", Config.scrollShortcut)) { UnscrollHandler.unscroll() }
            } else {
                Button(menuLabel("Scroll", Config.scrollShortcut)) { ScrollHandler.scroll() }
                    .disabled(menuState.isTiled)
            }
            if menuState.isScrolled {
                Button(menuLabel("Unscroll all", Config.scrollAllShortcut)) { UnscrollHandler.unscrollAll() }
            } else {
                Button(menuLabel("Scroll all", Config.scrollAllShortcut)) { ScrollAllHandler.organizeScrolling() }
                    .disabled(menuState.isTiled)
            }
            Divider()
            if WallpaperService.shared.isActive {
                Button(menuLabel("Disable wallpaper", Config.toggleWallpaperShortcut)) {
                    WallpaperService.shared.toggle()
                }
            } else {
                Button(menuLabel("Enable wallpaper", Config.toggleWallpaperShortcut)) {
                    WallpaperService.shared.toggle()
                }
            }
            if AutoModeService.shared.isEnabled {
                Button("Disable auto mode") { AutoModeService.shared.toggle() }
            } else {
                Button("Enable auto mode") { AutoModeService.shared.toggle() }
            }
            Divider()
            Button(menuLabel("Reset layout",  Config.resetLayoutShortcut))   { UntileHandler.untileAll(); TileAllHandler.tileAll() }
            Button(menuLabel("Refresh",       Config.refreshShortcut))        { ReapplyHandler.reapplyAll() }
            Divider()
            Button("Open config file") {
                NSWorkspace.shared.open(URL(fileURLWithPath: ConfigLoader.filePath))
            }
            Button("Reload config file") {
                Config.shared.reload()
                KeybindingService.shared.restart()
                if !Config.dimInactiveWindows { WindowOpacityService.shared.restoreAll() }
                WallpaperService.shared.apply()
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
                    if AutoModeService.shared.isEnabled { Text("[auto]") }
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
        }
        .menuBarExtraStyle(.menu)
    }
}
