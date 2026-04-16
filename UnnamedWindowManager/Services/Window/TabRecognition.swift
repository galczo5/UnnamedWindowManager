import ApplicationServices
import CoreGraphics
import Foundation

// Core tab recognition logic. Given a flat list of AX window elements, groups
// them by native tab membership: each window's AX subtree is walked for an
// AXTabGroup whose AXRadioButton children are matched back to sibling windows
// by (pid, title), with the tab-group owner's frame used as a tiebreaker when
// multiple candidate windows share a (pid, title) key.
enum TabRecognition {

    struct Result {
        let groups: [AXWindowImproved]
        // Windows that share (pid, title, frame) with another window and cannot
        // be uniquely attributed to a tab button. Callers should surface this
        // to the user and remove the affected windows from layout management.
        let ambiguous: [AXUIElement]
    }

    static func recognize(windows: [AXUIElement]) -> Result {
        let infos: [WindowInfo] = windows.map { element in
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            return WindowInfo(
                element: element,
                pid: pid,
                title: copyTitle(element),
                frame: readFrame(of: element)
            )
        }

        var byKey: [CandidateKey: [Int]] = [:]
        for (i, info) in infos.enumerated() {
            byKey[CandidateKey(pid: info.pid, title: info.title), default: []].append(i)
        }

        var claimed = Set<Int>()
        var ambiguous = Set<Int>()
        var results: [AXWindowImproved] = []

        for (i, info) in infos.enumerated() {
            if claimed.contains(i) { continue }

            guard let tabs = tabEntries(in: info.element), tabs.count > 1 else {
                claimed.insert(i)
                results.append(AXWindowImproved(window: info.element, tabs: []))
                continue
            }

            var tabWindows: [AXUIElement] = []
            var representative = info.element
            claimed.insert(i)

            for tab in tabs {
                let key = CandidateKey(pid: info.pid, title: tab.title)
                guard let candidates = byKey[key] else { continue }
                let pick = pickCandidate(candidates: candidates,
                                         infos: infos,
                                         claimed: claimed,
                                         ownerIndex: i,
                                         ownerFrame: info.frame)
                if let ambiguousSet = pick.ambiguous {
                    ambiguous.formUnion(ambiguousSet)
                }
                guard let idx = pick.index else { continue }

                let sibling = infos[idx].element
                tabWindows.append(sibling)
                claimed.insert(idx)
                if tab.selected { representative = sibling }
            }
            results.append(AXWindowImproved(window: representative, tabs: tabWindows))
        }
        return Result(groups: results, ambiguous: ambiguous.sorted().map { infos[$0].element })
    }

    private struct WindowInfo {
        let element: AXUIElement
        let pid: pid_t
        let title: String
        let frame: CGRect?
    }

    private struct CandidateKey: Hashable {
        let pid: pid_t
        let title: String
    }

    struct CandidatePick {
        let index: Int?
        let ambiguous: [Int]?
    }

    // Picks the best candidate for a tab button. Preference order:
    // 1. The owner window itself (if (pid, title) matches — covers the "self tab").
    // 2. An unclaimed candidate whose frame matches the owner's frame (same tab group).
    // 3. Any unclaimed candidate.
    // 4. Any candidate (last resort — will duplicate a sibling).
    //
    // If step 2 yields ≥2 unclaimed candidates with matching frames, we cannot
    // uniquely identify the sibling. Returns them as `ambiguous` so the caller
    // can flag those windows for the user.
    private static func pickCandidate(candidates: [Int],
                                      infos: [WindowInfo],
                                      claimed: Set<Int>,
                                      ownerIndex: Int,
                                      ownerFrame: CGRect?) -> CandidatePick {
        if candidates.contains(ownerIndex) {
            return CandidatePick(index: ownerIndex, ambiguous: nil)
        }

        let unclaimed = candidates.filter { !claimed.contains($0) }
        if let frame = ownerFrame {
            let matching = unclaimed.filter { framesMatch(infos[$0].frame, frame) }
            if matching.count >= 2 {
                return CandidatePick(index: matching.first, ambiguous: matching)
            }
            if let match = matching.first {
                return CandidatePick(index: match, ambiguous: nil)
            }
        }
        return CandidatePick(index: unclaimed.first ?? candidates.first, ambiguous: nil)
    }

    private static func framesMatch(_ a: CGRect?, _ b: CGRect) -> Bool {
        guard let a = a else { return false }
        let tol: CGFloat = 2.0
        return abs(a.origin.x - b.origin.x) <= tol
            && abs(a.origin.y - b.origin.y) <= tol
            && abs(a.size.width - b.size.width) <= tol
            && abs(a.size.height - b.size.height) <= tol
    }

    private static func readFrame(of element: AXUIElement) -> CGRect? {
        guard let origin = readOrigin(of: element), let size = readSize(of: element) else { return nil }
        return CGRect(origin: origin, size: size)
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
            let isSelected = ((valueValue as? Int) == 1) || ((valueValue as? Bool) == true)
            tabs.append(TabEntry(title: (titleValue as? String) ?? "", selected: isSelected))
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
