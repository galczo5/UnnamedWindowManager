//
//  WindowLister.swift
//  UnnamedWindowManager
//

import AppKit
import ApplicationServices

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
                guard let wid = WindowSnapper.windowID(of: axWindow), wids.contains(wid) else { continue }

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
}
