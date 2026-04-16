import AppKit

struct OnScreenWindow: Hashable {
    let windowID: CGWindowID
    let pid: pid_t
    let hash: UInt

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.pid == rhs.pid && lhs.hash == rhs.hash }
    func hash(into hasher: inout Hasher) { hasher.combine(pid); hasher.combine(hash) }
}

extension Set<OnScreenWindow> {
    func contains(pid: pid_t, hash: UInt) -> Bool {
        contains(OnScreenWindow(windowID: CGWindowID(hash), pid: pid, hash: hash))
    }
}

// Queries CGWindowListCopyWindowInfo for windows currently visible on screen.
enum WindowOnScreenCache {
    static func visibleSet() -> Set<OnScreenWindow> {
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var result = Set<OnScreenWindow>()
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid   = info[kCGWindowOwnerPID as String] as? Int,
                  let wid   = info[kCGWindowNumber as String] as? CGWindowID,
                  pid_t(pid) != ownPID
            else { continue }
            result.insert(OnScreenWindow(windowID: wid, pid: pid_t(pid), hash: UInt(wid)))
        }
        return result
    }
}
