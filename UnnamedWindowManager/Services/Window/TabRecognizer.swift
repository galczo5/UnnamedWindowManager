import AppKit
import Foundation
import ApplicationServices
import CoreGraphics

// Recognises native macOS tab groups by walking the AX subtree of each window,
// locating an AXTabGroup element and resolving its AXRadioButton children back
// to the sibling AX windows that share their titles.
enum TabRecognizer {

    /// Returns the tab group `window` belongs to — representative AX element + every
    /// sibling tab AX element — by running recognition over every window in every
    /// running app. Returns nil if the window is not part of a multi-tab group.
    static func isTab(_ window: AXUIElement) -> AXWindowImproved? {
        let groups = cachedRecognizeAll()
        for group in groups where group.tabs.count > 1 {
            if CFEqual(group.window, window) { return group }
            for tab in group.tabs where CFEqual(tab, window) { return group }
        }
        return nil
    }

    /// Returns the full tab group hashes for the window identified by `hash` / `pid`,
    /// including itself. Returns an empty set if the window has no tab siblings.
    static func tabSiblingHashes(of hash: UInt, pid: pid_t) -> Set<UInt> {
        guard let ax = axWindow(forHash: hash, pid: pid),
              let group = isTab(ax) else { return [] }
        return Set(group.tabs.compactMap { windowID(of: $0).map(UInt.init) })
    }

    /// Given candidate CGWindowIDs for one PID, returns the subset to keep after filtering
    /// out tab duplicates. Keeps the selected tab per group (falls back to smallest wid).
    static func filterTabDuplicates(wids: Set<CGWindowID>, pid: pid_t) -> (kept: Set<CGWindowID>, hadTabs: Bool) {
        var keep = Set<CGWindowID>()
        var hadTabs = false
        var processed = Set<CGWindowID>()

        for wid in wids {
            if processed.contains(wid) { continue }
            guard let ax = axWindow(forHash: UInt(wid), pid: pid) else {
                keep.insert(wid); processed.insert(wid); continue
            }
            if let group = isTab(ax) {
                hadTabs = true
                let groupWids = Set(group.tabs.compactMap { windowID(of: $0) }).intersection(wids)
                if let rep = windowID(of: group.window), wids.contains(rep) {
                    keep.insert(rep)
                } else if let first = groupWids.min() {
                    keep.insert(first)
                }
                processed.formUnion(groupWids)
                processed.insert(wid)
            } else {
                keep.insert(wid)
                processed.insert(wid)
            }
        }
        return (keep, hadTabs)
    }

    // Per-app AX calls can block if the target app is unresponsive. A short
    // messaging timeout caps the worst-case blocking per element. The result
    // cache collapses bursts (focus change + subsequent batch lookups) into
    // a single enumeration pass.
    private static let axTimeoutSeconds: Float = 0.1
    private static let cacheTTL: TimeInterval = 0.5
    private static var cachedGroups: [AXWindowImproved] = []
    private static var cachedAt: Date = .distantPast

    private static func cachedRecognizeAll() -> [AXWindowImproved] {
        if Date().timeIntervalSince(cachedAt) < cacheTTL { return cachedGroups }
        let groups = TabRecognition.recognize(windows: collectAllWindows())
        cachedGroups = groups
        cachedAt = Date()
        return groups
    }

    static func collectAllWindows() -> [AXUIElement] {
        let regularPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { $0.processIdentifier })

        // CGWindowList returns windows across every Space, so it's the right source
        // for "which PIDs actually own real windows".
        let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var pids: [pid_t] = []
        var seenPIDs = Set<pid_t>()
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  regularPIDs.contains(pid),
                  !seenPIDs.contains(pid) else { continue }
            pids.append(pid)
            seenPIDs.insert(pid)
        }

        var all: [AXUIElement] = []
        for pid in pids {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, axTimeoutSeconds)

            var seenWids = Set<CGWindowID>()
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
               let axWindows = ref as? [AXUIElement] {
                for w in axWindows {
                    AXUIElementSetMessagingTimeout(w, axTimeoutSeconds)
                    if let wid = windowID(of: w) { seenWids.insert(wid) }
                    all.append(w)
                }
            }

            // Supplement with a brute-force private-AX probe for windows on other Spaces.
            for w in windowsByBruteForce(pid) {
                AXUIElementSetMessagingTimeout(w, axTimeoutSeconds)
                if let wid = windowID(of: w) {
                    if seenWids.insert(wid).inserted { all.append(w) }
                } else {
                    all.append(w)
                }
            }
        }
        return all
    }

}
