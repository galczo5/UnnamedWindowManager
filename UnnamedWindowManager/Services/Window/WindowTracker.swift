import AppKit
import ApplicationServices

// Tracks the mapping between WindowSlots, AXUIElements, and PIDs for all tiled/scrolled windows.
// Central registry for window identity and observation state.
final class WindowTracker {
    static let shared = WindowTracker()
    private init() {}

    var elements:   [WindowSlot: AXUIElement] = [:]
    var keysByPid:  [pid_t: Set<WindowSlot>]  = [:]
    var keysByHash: [UInt: WindowSlot]         = [:]
    /// Keys whose reapply is in-flight; prevents re-entrancy from the resulting AX notification.
    var reapplying: Set<WindowSlot>            = []

    private(set) lazy var reapplyScheduler = TilingDragHandler(tracker: self)

    func register(key: WindowSlot, element: AXUIElement, pid: pid_t) {
        elements[key] = element
        keysByPid[pid, default: []].insert(key)
        keysByHash[key.windowHash] = key
    }

    func window(for key: WindowSlot) -> AXUIElement? {
        elements[key]
    }

    func cleanup(key: WindowSlot, pid: pid_t) {
        reapplyScheduler.cancel(key: key)
        reapplyScheduler.overlay.hide()
        reapplying.remove(key)
        elements.removeValue(forKey: key)
        keysByHash.removeValue(forKey: key.windowHash)
        keysByPid[pid]?.remove(key)

    }
}
