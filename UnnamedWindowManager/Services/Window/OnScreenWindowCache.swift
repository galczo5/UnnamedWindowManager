import AppKit

// Time-cached CGWindowListCopyWindowInfo result, shared across callers to avoid
// redundant window-server queries within the same operation burst.
enum OnScreenWindowCache {
    private static var cachedHashes: Set<UInt> = []
    private static var cacheTime: UInt64 = 0

    static func invalidate() { cacheTime = 0 }

    static func visibleHashes() -> Set<UInt> {
        let now = DispatchTime.now().uptimeNanoseconds
        if now - cacheTime < 50_000_000, !cachedHashes.isEmpty {
            return cachedHashes
        }
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var ids = Set<UInt>()
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid   = info[kCGWindowOwnerPID as String] as? Int,
                  let wid   = info[kCGWindowNumber as String] as? CGWindowID,
                  pid_t(pid) != ownPID
            else { continue }
            ids.insert(UInt(wid))
        }
        cachedHashes = ids
        cacheTime = now
        return ids
    }
}
