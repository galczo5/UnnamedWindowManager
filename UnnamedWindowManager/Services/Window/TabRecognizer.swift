import AppKit
import Foundation
import ApplicationServices
import CoreGraphics

// Private AX SPI: creates an AXUIElement for the given remote token. Used to
// enumerate windows on other Spaces, which `kAXWindowsAttribute` does not return.
@_silgen_name("_AXUIElementCreateWithRemoteToken") @discardableResult
private func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

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
        let groups = recognize(windows: collectAllWindows())
        cachedGroups = groups
        cachedAt = Date()
        return groups
    }

    /// Logs every collected AX window, then the result of `recognize`. Invoked
    /// from the app's Debug menu — never fires on ordinary focus/tile paths.
    static func debugLog() {
        let all = collectAllWindows()
        var lines: [String] = ["TabRecognizer.debug: \(all.count) window(s)"]
        for window in all {
            lines.append("  \(describe(window))")
        }
        Logger.shared.log(lines.joined(separator: "\n"))

        let groups = recognize(windows: all)
        var groupLines: [String] = ["TabRecognizer.debug: recognize → \(groups.count) group(s)"]
        for (i, group) in groups.enumerated() {
            groupLines.append("- group \(i + 1): \(describe(group.window))")
            for (j, tab) in group.tabs.enumerated() {
                groupLines.append("   - tab \(j + 1): \(describe(tab))")
            }
        }
        Logger.shared.log(groupLines.joined(separator: "\n"))
    }

    private static func collectAllWindows() -> [AXUIElement] {
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

    // Probes AX element IDs 0..1000 for the given PID, returning elements whose
    // subrole is AXStandardWindow or AXDialog. Time-capped at 0.1s. This catches
    // windows on other Spaces that `kAXWindowsAttribute` doesn't expose. Technique
    // borrowed from alt-tab-macos via UnnamedMenu.
    private static func windowsByBruteForce(_ pid: pid_t) -> [AXUIElement] {
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        var results: [AXUIElement] = []
        let start = Date()
        for id: UInt64 in 0..<1000 {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
            guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            var subrole: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
               let subroleStr = subrole as? String,
               [kAXStandardWindowSubrole, kAXDialogSubrole].contains(subroleStr) {
                results.append(element)
            }
            if Date().timeIntervalSince(start) > 0.1 { break }
        }
        return results
    }

    private static func recognize(windows: [AXUIElement]) -> [AXWindowImproved] {
        var byTitle: [String: AXUIElement] = [:]
        var orderedTitles: [String] = []
        for window in windows {
            let title = copyTitle(window)
            if byTitle[title] == nil {
                byTitle[title] = window
                orderedTitles.append(title)
            }
        }

        var claimed = Set<String>()
        var results: [AXWindowImproved] = []

        for title in orderedTitles {
            guard !claimed.contains(title), let window = byTitle[title] else { continue }

            guard let tabs = tabEntries(in: window), tabs.count > 1 else {
                claimed.insert(title)
                results.append(AXWindowImproved(window: window, tabs: []))
                continue
            }

            var tabWindows: [AXUIElement] = []
            var representative = window
            for tab in tabs {
                guard let sibling = byTitle[tab.title] else { continue }
                tabWindows.append(sibling)
                claimed.insert(tab.title)
                if tab.selected { representative = sibling }
            }
            results.append(AXWindowImproved(window: representative, tabs: tabWindows))
        }
        return results
    }

    private static func describe(_ element: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let wid = windowID(of: element).map(String.init) ?? "nil"
        let title = copyTitle(element)
        return "Window(pid: \(pid), id: \(wid), title: \"\(title)\")"
    }

    private struct TabEntry { let title: String; let selected: Bool }

    private static func copyTitle(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        return (value as? String) ?? ""
    }

    private static func tabEntries(in window: AXUIElement) -> [TabEntry]? {
        guard let tabGroup = findTabGroup(in: window, depth: 0) else { return nil }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(tabGroup, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }
        var tabs: [TabEntry] = []
        for child in children {
            var roleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue) == .success,
                  let role = roleValue as? String, role == kAXRadioButtonRole else { continue }
            var titleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleValue)
            var valueValue: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valueValue)
            let selected = (valueValue as? Int ?? 0) == 1 || (valueValue as? Bool ?? false)
            tabs.append(TabEntry(title: (titleValue as? String) ?? "", selected: selected))
        }
        return tabs.isEmpty ? nil : tabs
    }

    // The tab group is usually a direct child of the window, but some apps nest
    // it one level deeper inside a splitter/group — depth-limited DFS handles both.
    private static func findTabGroup(in element: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 3 { return nil }
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String, role == kAXTabGroupRole {
            return element
        }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findTabGroup(in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}
