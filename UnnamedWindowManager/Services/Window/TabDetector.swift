import AppKit
import ApplicationServices

/// Detects native macOS tab groups by identifying same-PID windows with identical CGWindow bounds.
/// Queries CGWindowListCopyWindowInfo without .optionOnScreenOnly so that inactive tabs
/// (which share the same window frame but aren't rendered) are included in the results.
struct TabDetector {

    struct WindowInfo {
        let wid: CGWindowID
        let pid: pid_t
        let bounds: CGRect
    }

    /// Returns the full tab group hashes for a given window, including itself.
    /// Returns an empty set if the window has no tab siblings.
    /// Queries ALL windows (not just on-screen) so inactive tabs are visible.
    static func tabSiblingHashes(of hash: UInt, pid: pid_t) -> Set<UInt> {
        let infos = allWindowInfos(forPid: pid)
        guard let target = infos.first(where: { UInt($0.wid) == hash })
        else { return [] }
        let group = Set(infos.filter { $0.bounds == target.bounds }.map { UInt($0.wid) })
        return group.count > 1 ? group : []
    }

    /// Given a set of candidate CGWindowIDs for a single PID, returns the subset to keep
    /// after filtering out tab duplicates. Keeps the smallest wid per tab group.
    static func filterTabDuplicates(wids: Set<CGWindowID>, pid: pid_t) -> (kept: Set<CGWindowID>, hadTabs: Bool) {
        let infos = allWindowInfos(forPid: pid).filter { wids.contains($0.wid) }
        var grouped: [String: [CGWindowID]] = [:]
        for info in infos {
            let key = boundsKey(info.bounds)
            grouped[key, default: []].append(info.wid)
        }
        var keep = Set<CGWindowID>()
        var hadTabs = false
        for (_, group) in grouped {
            keep.insert(group.min()!)
            if group.count > 1 { hadTabs = true }
        }
        // Include any wids not found in CGWindowList (fallback identity windows).
        let matched = Set(infos.map(\.wid))
        for wid in wids where !matched.contains(wid) {
            keep.insert(wid)
        }
        return (keep, hadTabs)
    }

    /// Returns ALL windows for a specific PID (including off-screen / inactive tabs).
    private static func allWindowInfos(forPid targetPid: pid_t) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var result: [WindowInfo] = []
        for info in list {
            guard let layer  = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid    = info[kCGWindowOwnerPID as String] as? Int,
                  pid_t(pid) == targetPid,
                  let wid    = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"]
            else { continue }
            result.append(WindowInfo(wid: wid, pid: targetPid,
                                     bounds: CGRect(x: x, y: y, width: w, height: h)))
        }
        return result
    }

    private static func boundsKey(_ b: CGRect) -> String {
        "\(b.origin.x)-\(b.origin.y)-\(b.width)-\(b.height)"
    }
}
