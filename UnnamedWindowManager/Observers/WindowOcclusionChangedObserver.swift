import AppKit

// Observes NSWindow occlusion state changes and fires WindowOcclusionChangedEvent.
// Registers per-window NSNotification observers; multiple windows can be observed independently.
final class WindowOcclusionChangedObserver: EventObserver<WindowOcclusionChangedEvent> {
    static let shared = WindowOcclusionChangedObserver()
    private var observed: [ObjectIdentifier: NSObjectProtocol] = [:]

    private override init() {}

    @discardableResult
    func subscribe(window: NSWindow, handler: @escaping (WindowOcclusionChangedEvent) -> Void) -> UUID {
        let id = super.subscribe("WindowOcclusionChangedObserver:subscribe(\(window.windowNumber))", handler: handler)
        let winID = ObjectIdentifier(window)
        if observed[winID] == nil {
            let obs = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let window else { return }
                let visible = window.occlusionState.contains(.visible)
                self?.notify(WindowOcclusionChangedEvent(window: window, isVisible: visible))
            }
            observed[winID] = obs
        }
        return id
    }

    func stopObserving(window: NSWindow) {
        let winID = ObjectIdentifier(window)
        if let obs = observed.removeValue(forKey: winID) {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}
