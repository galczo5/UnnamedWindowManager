import Foundation

// Holds the enabled/disabled state for auto mode. State is in-memory and resets on relaunch.
@Observable
final class AutoModeService {
    static let shared = AutoModeService()
    private init() {}

    var isEnabled: Bool = false

    func toggle() {
        isEnabled.toggle()
    }
}
