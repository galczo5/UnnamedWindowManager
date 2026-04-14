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
    /// Frames (AX coords, top-left origin) sampled just before an in-flight reapply began.
    /// Callers should prefer `preReapplyFrame(for:)` which enforces the "only while reapplying" guard.
    var preReapplyFrames: [WindowSlot: CGRect] = [:]

    /// Returns the key's frame captured before the current in-flight reapply started,
    /// or nil once that reapply has drained. Callers can fall back to a live AX read when nil.
    func preReapplyFrame(for key: WindowSlot) -> CGRect? {
        guard reapplying.contains(key) else { return nil }
        return preReapplyFrames[key]
    }

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
        preReapplyFrames.removeValue(forKey: key)
        elements.removeValue(forKey: key)
        keysByHash.removeValue(forKey: key.windowHash)
        keysByPid[pid]?.remove(key)

    }
}
