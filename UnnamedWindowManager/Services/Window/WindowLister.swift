import AppKit
import ApplicationServices

// Debugging utilities that log all on-screen windows and the current slot tree.
struct WindowLister {

    /// Logs a tile/scroll event: which window moved to which root, and all currently visible
    /// on-screen windows annotated with the root they belong to (or "untiled").
    static func logWindowEvent(action: String, windowHash: UInt, rootID: UUID) {
        let (visibleWindows, hashToRootID, roots) = snapshotVisibleWindows()
        let windowCount: Int
        switch roots[rootID] {
        case .tiling(let r):    windowCount = r.allLeaves().count
        case .scrolling(let r): windowCount = countScrollingWindows(in: r)
        case nil:               windowCount = 0
        }
        Logger.shared.log("\(action) wid=\(windowHash) root=\(rootID.uuidString.prefix(8)) windows=\(windowCount)")
        logVisibleWindows(visibleWindows, hashToRootID: hashToRootID)
    }

    /// Logs that the active visible root has changed (e.g. after a Space switch),
    /// followed by all on-screen windows annotated with their root.
    /// Warns if windows from multiple roots are visible simultaneously.
    static func logRootChanged(type: String, rootID: UUID, windowCount: Int) {
        Logger.shared.log("root changed [\(type)] root=\(rootID.uuidString.prefix(8)) windows=\(windowCount)")
        let (visibleWindows, hashToRootID, _) = snapshotVisibleWindows()
        let visibleRootIDs = Set(visibleWindows.compactMap { hashToRootID[$0.hash] })
        if visibleRootIDs.count > 1 {
            let ids = visibleRootIDs.map { String($0.uuidString.prefix(8)) }.sorted().joined(separator: ", ")
            Logger.shared.log("  WARNING: windows from \(visibleRootIDs.count) roots visible on same desktop [\(ids)]")
        }
        logVisibleWindows(visibleWindows, hashToRootID: hashToRootID)
    }

    // Queries CGWindowList and the root store, returning visible windows and a hash→rootID map.
    private static func snapshotVisibleWindows()
        -> (windows: [(hash: UInt, app: String, title: String)], hashToRootID: [UInt: UUID], roots: [UUID: RootSlot])
    {
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let cgList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        var visibleWindows: [(hash: UInt, app: String, title: String)] = []
        for info in cgList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid   = info[kCGWindowOwnerPID as String] as? Int,
                  let wid   = info[kCGWindowNumber as String] as? CGWindowID,
                  pid_t(pid) != ownPID
            else { continue }
            let app   = info[kCGWindowOwnerName as String] as? String ?? "unknown"
            let title = info[kCGWindowName as String] as? String ?? ""
            visibleWindows.append((hash: UInt(wid), app: app, title: title))
        }

        let roots = SharedRootStore.shared.snapshotAllRoots()
        var hashToRootID: [UInt: UUID] = [:]
        for (id, rootSlot) in roots {
            switch rootSlot {
            case .tiling(let root):
                for leaf in root.allLeaves() {
                    if case .window(let w) = leaf { hashToRootID[w.windowHash] = id }
                }
            case .scrolling(let root):
                func collect(_ slot: Slot) {
                    switch slot {
                    case .window(let w):   hashToRootID[w.windowHash] = id
                    case .stacking(let s): s.children.forEach { hashToRootID[$0.windowHash] = id }
                    default: break
                    }
                }
                if let left = root.left { collect(left) }
                collect(root.center)
                if let right = root.right { collect(right) }
            }
        }
        return (visibleWindows, hashToRootID, roots)
    }

    private static func logVisibleWindows(
        _ windows: [(hash: UInt, app: String, title: String)],
        hashToRootID: [UInt: UUID]
    ) {
        for win in windows {
            let winRoot = hashToRootID[win.hash].map { String($0.uuidString.prefix(8)) } ?? "untiled"
            let label   = win.title.isEmpty ? win.app : "\(win.app) – \(win.title)"
            Logger.shared.log("  visible wid=\(win.hash) root=\(winRoot) \"\(label)\"")
        }
    }

    static func countScrollingWindows(in root: ScrollingRootSlot) -> Int {
        var count = 0
        func countSlot(_ slot: Slot) {
            switch slot {
            case .window:          count += 1
            case .stacking(let s): count += s.children.count
            default: break
            }
        }
        if let left = root.left { countSlot(left) }
        countSlot(root.center)
        if let right = root.right { countSlot(right) }
        return count
    }

    static func logAllWindows() {
        guard AXIsProcessTrusted() else {
            Logger.shared.log("AX not trusted")
            return
        }

        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)

        guard let cgList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        var pidToWindowIDs: [pid_t: Set<CGWindowID>] = [:]
        for info in cgList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid   = info[kCGWindowOwnerPID as String] as? Int,
                  let wid   = info[kCGWindowNumber as String] as? CGWindowID,
                  pid_t(pid) != ownPID
            else { continue }
            pidToWindowIDs[pid_t(pid), default: []].insert(wid)
        }

        Logger.shared.log("=== All windows ===")
        for (pid, wids) in pidToWindowIDs.sorted(by: { $0.key < $1.key }) {
            let axApp = AXUIElementCreateApplication(pid)

            var appNameRef: CFTypeRef?
            let appName: String
            if AXUIElementCopyAttributeValue(axApp, kAXTitleAttribute as CFString, &appNameRef) == .success,
               let name = appNameRef as? String {
                appName = name
            } else {
                appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "unknown"
            }

            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                guard let wid = windowID(of: axWindow), wids.contains(wid) else { continue }

                var titleRef: CFTypeRef?
                let title: String
                if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let t = titleRef as? String {
                    title = t.isEmpty ? "(no title)" : t
                } else {
                    title = "(no title)"
                }

                Logger.shared.log("wid=\(wid) app=\"\(appName)\" title=\"\(title)\"")
            }
        }
        Logger.shared.log("=== End of windows ===")
    }

    static func logSlotTree() {
        let roots = SharedRootStore.shared.snapshotAllRoots()
        Logger.shared.log("=== Slot trees (\(roots.count) roots) ===")
        for (id, rootSlot) in roots.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            switch rootSlot {
            case .tiling(let root):
                Logger.shared.log("root \(id.uuidString.prefix(8))  size=\(Int(root.size.width))x\(Int(root.size.height))  orientation=\(root.orientation)  children=\(root.children.count)")
                for child in root.children { logSlot(child, depth: 1) }
            case .scrolling(let root):
                Logger.shared.log("scrolling root \(id.uuidString.prefix(8))  size=\(Int(root.size.width))x\(Int(root.size.height))")
                if let left = root.left  { Logger.shared.log("  [left]");   logSlot(left,        depth: 1) }
                Logger.shared.log("  [center]"); logSlot(root.center, depth: 1)
                if let right = root.right { Logger.shared.log("  [right]");  logSlot(right, depth: 1) }
            }
        }
        Logger.shared.log("=== End of slot trees ===")
    }

    private static func logSlot(_ slot: Slot, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        switch slot {
        case .window(let w):
            let ax = WindowTracker.shared.elements[w]
            let actualSize = ax.flatMap { readSize(of: $0) }
            let actualStr = actualSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? (ax == nil ? "no-element" : "no-size")
            Logger.shared.log("\(indent)window  size=\(w.size.width)x\(w.size.height)  actual=\(actualStr)  fraction=\(w.fraction)  pid=\(w.pid)  hash=\(w.windowHash)")
        case .split(let s):
            Logger.shared.log("\(indent)\(s.orientation)  size=\(s.size.width)x\(s.size.height)  fraction=\(s.fraction)  children=\(s.children.count)")
            for child in s.children { logSlot(child, depth: depth + 1) }
        case .stacking(let s):
            Logger.shared.log("\(indent)stacking  size=\(s.size.width)x\(s.size.height)  fraction=\(s.fraction)  align=\(s.align)  children=\(s.children.count)")
        }
    }
}
