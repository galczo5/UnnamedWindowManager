import AppKit
import ApplicationServices

// Debugging utilities that log all on-screen windows and the current slot tree.
struct WindowLister {

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
        for (id, root) in roots.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            Logger.shared.log("root \(id.uuidString.prefix(8))  size=\(Int(root.width))x\(Int(root.height))  orientation=\(root.orientation)  children=\(root.children.count)")
            for child in root.children { logSlot(child, depth: 1) }
        }
        Logger.shared.log("=== End of slot trees ===")
    }

    private static func logSlot(_ slot: Slot, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        switch slot {
        case .window(let w):
            let ax = ResizeObserver.shared.elements[w]
            let actualSize = ax.flatMap { readSize(of: $0) }
            let actualStr = actualSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? (ax == nil ? "no-element" : "no-size")
            Logger.shared.log("\(indent)window  size=\(w.width)x\(w.height)  actual=\(actualStr)  fraction=\(w.fraction)  pid=\(w.pid)  hash=\(w.windowHash)")
        case .horizontal(let h):
            Logger.shared.log("\(indent)horizontal  size=\(h.width)x\(h.height)  fraction=\(h.fraction)  children=\(h.children.count)")
            for child in h.children { logSlot(child, depth: depth + 1) }
        case .vertical(let v):
            Logger.shared.log("\(indent)vertical  size=\(v.width)x\(v.height)  fraction=\(v.fraction)  children=\(v.children.count)")
            for child in v.children { logSlot(child, depth: depth + 1) }
        }
    }
}
