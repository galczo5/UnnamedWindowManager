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
        AppActivatedObserver.shared.start()
        AppTerminatedObserver.shared.start()
        FocusedWindowChangedObserver.shared.start()
        ScreenParametersChangedObserver.shared.start()
        SpaceChangedObserver.shared.start()
        WindowCreatedObserver.shared.start()
        KeyDownObserver.shared.start()
        WallpaperService.shared.apply()

        FocusedWindowChangedObserver.shared.subscribe { event in
            WindowFocusChangedObserver.shared.notify(WindowFocusChangedEvent())
            FocusChangeHandler.shared.handleFocusChange(pid: event.pid)
        }

        WindowCreatedObserver.shared.subscribe { event in
            let label = event.title.isEmpty ? event.appName : "\(event.appName) – \(event.title)"
            let key = windowSlot(for: event.window, pid: event.pid)
            let rootDesc: String
            if let rootID = TilingRootStore.shared.rootID(containing: key) {
                rootDesc = "tiling:\(rootID.uuidString.prefix(8))"
            } else if let info = ScrollingRootStore.shared.scrollingRootInfo(containing: key) {
                rootDesc = "scrolling:\(info.rootID.uuidString.prefix(8))"
            } else {
                rootDesc = "untiled"
            }
            Logger.shared.log("window appeared \"\(label)\" pid=\(event.pid) wid=\(event.windowHash ?? 0) root=\(rootDesc)")
            AutoModeHandler.handleFocusChange()
        }

        let tracker = WindowTracker.shared
        let router = WindowEventRouter.shared

        WindowDestroyedObserver.shared.subscribe { event in
            let isScrolling = ScrollingRootStore.shared.isTracked(event.key)
            router.removeWindow(key: event.key, pid: event.pid, isScrolling: isScrolling)
        }
        WindowMiniaturizedObserver.shared.subscribe { event in
            let isScrolling = ScrollingRootStore.shared.isTracked(event.key)
            router.removeWindow(key: event.key, pid: event.pid, isScrolling: isScrolling)
        }
        WindowResizedObserver.shared.subscribe { event in
            let isScrolling = ScrollingRootStore.shared.isTracked(event.key)
            if event.isFullScreen {
                router.removeWindow(key: event.key, pid: event.pid, isScrolling: isScrolling)
                return
            }
            if let axElement = tracker.elements[event.key] {
                FocusedWindowBorderService.shared.updateIfActive(key: event.key, axElement: axElement)
            }
            guard TilingRootStore.shared.isTracked(event.key) || isScrolling else { return }
            guard !tracker.reapplying.contains(event.key) else { return }
            tracker.reapplyScheduler.schedule(key: event.key, isResize: true, isScrolling: isScrolling)
        }
        WindowMovedObserver.shared.subscribe { event in
            let isScrolling = ScrollingRootStore.shared.isTracked(event.key)
            if let axElement = tracker.elements[event.key] {
                FocusedWindowBorderService.shared.updateIfActive(key: event.key, axElement: axElement)
            }
            guard TilingRootStore.shared.isTracked(event.key) || isScrolling else { return }
            guard !tracker.reapplying.contains(event.key) else { return }
            if !isScrolling && NSEvent.pressedMouseButtons != 0 {
                tracker.reapplyScheduler.updateDragOverlay(forKey: event.key, element: event.element, elements: tracker.elements)
            }
            tracker.reapplyScheduler.schedule(key: event.key, isResize: false, isScrolling: isScrolling)
        }

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
