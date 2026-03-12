import AppKit

// Observes screen configuration changes (resolution, display connect/disconnect)
// and reflows the layout to match the new screen dimensions.
final class ScreenChangeObserver {
    static let shared = ScreenChangeObserver()
    private init() {}

    func start() {
        Logger.shared.log("start")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        guard let screen = NSScreen.main else { return }
        TileService.shared.recomputeVisibleRootSizes(screen: screen)
        ReapplyHandler.reapplyAll()
    }
}
